require "rails_helper"
require "open3"
require "zlib"

# bin/backup, run for real against stand-ins on PATH: pg_dump prints a dump, psql records what it was fed, and aws
# keeps "R2" in a folder (s3 cp both ways, s3 rm, s3 ls and s3api list-objects-v2). gzip and gunzip are the real ones.
RSpec.describe "bin/backup" do
  let(:dir) { Pathname(Dir.mktmpdir("backup-spec")) }
  let(:bucket) { dir.join("r2") }
  let(:calls) { dir.join("calls.log") }
  let(:env) do
    { "PATH" => "#{dir.join('bin')}:#{ENV.fetch('PATH')}", "FAKE_DIR" => dir.to_s, "BACKUP_STATE_DIR" => dir.to_s,
      "PGDATABASE" => "midrolo_production", "R2_ACCOUNT_ID" => "acct", "R2_ACCESS_KEY_ID" => "key",
      "R2_SECRET_ACCESS_KEY" => "secret", "R2_BACKUP_BUCKET" => "backups" }
  end

  before do
    dir.join("bin").mkpath
    stub_command("pg_dump", <<~SH)
      echo "pg_dump $*" >> "$FAKE_DIR/calls.log"
      echo "-- dump of $PGDATABASE"
      [ -z "${FAKE_PG_DUMP_FAILS:-}" ] || exit 1
      echo "CREATE TABLE shows (id bigint);"
    SH
    stub_command("psql", <<~SH)
      echo "psql $*" >> "$FAKE_DIR/calls.log"
      cat > "$FAKE_DIR/psql.in"
    SH
    stub_command("aws", <<~SH)
      echo "aws $*" >> "$FAKE_DIR/calls.log"
      shift 2 # --endpoint-url URL
      store="$FAKE_DIR/r2"
      case "$1 $2" in
        "s3 cp")
          if [ "$3" = "-" ]; then
            [ -z "${FAKE_UPLOAD_FAILS:-}" ] || { cat > /dev/null; exit 1; }
            key="${4#s3://*/}"; mkdir -p "$(dirname "$store/$key")"; cat > "$store/$key"
          else
            key="${3#s3://*/}"; cat "$store/$key"
          fi ;;
        "s3 rm") key="${3#s3://*/}"; rm -f "$store/$key" ;;
        "s3 ls") ls "$store/midrolo" ;;
        "s3api list-objects-v2")
          keys=$(cd "$store" && find midrolo -type f | sort | paste -sd '\\t' -)
          echo "${keys:-None}" ;;
        *) echo "unexpected: $*" >&2; exit 2 ;;
      esac
    SH
  end

  after { FileUtils.rm_rf(dir) }

  def stub_command(name, body)
    path = dir.join("bin", name)
    path.write("#!/usr/bin/env bash\nset -euo pipefail\n#{body}")
    path.chmod(0o755)
  end

  def backup(*args, env: self.env) = Open3.capture3(env, Rails.root.join("bin/backup").to_s, *args)

  def stamp(time) = "midrolo-#{time.utc.strftime('%Y-%m-%dT%H%M%SZ')}.sql.gz"

  let(:old) { stamp(20.days.ago) }

  def put(name, content = "old")
    bucket.join("midrolo").mkpath
    bucket.join("midrolo", name).binwrite(content)
  end

  def stored = bucket.join("midrolo").children.map { |path| path.basename.to_s }.sort

  it "streams a gzipped dump to R2, then deletes only its own backups over 14 days old" do
    recent = stamp(10.days.ago)
    put(old)
    put(recent)
    put("notes.txt")

    out, err, status = backup
    expect(status).to be_success, err

    fresh = stored.find { |name| name.start_with?("midrolo-#{Time.now.utc.strftime('%Y-%m-%d')}") }
    expect(out).to include("uploaded #{fresh}")
    expect(Zlib.gunzip(bucket.join("midrolo", fresh).binread)).to eq("-- dump of midrolo_production\nCREATE TABLE shows (id bigint);\n")
    expect(stored).to contain_exactly(fresh, recent, "notes.txt")
    expect(calls.read).to include("pg_dump --no-owner --no-privileges")
    expect(calls.read.lines.grep(/\Aaws /)).to all(start_with("aws --endpoint-url https://acct.r2.cloudflarestorage.com "))
  end

  it "fails, keeping no partial upload and deleting nothing, when pg_dump fails" do
    put(old)
    _out, err, status = backup(env: env.merge("FAKE_PG_DUMP_FAILS" => "1"))

    expect(status).not_to be_success
    expect(err).to include("backup: failed")
    expect(stored).to eq([ old ])
  end

  it "fails and deletes nothing when the upload fails" do
    put(old)
    _out, _err, status = backup(env: env.merge("FAKE_UPLOAD_FAILS" => "1"))

    expect(status).not_to be_success
    expect(stored).to eq([ old ])
  end

  it "names a missing R2 setting before touching the database" do
    _out, err, status = backup(env: env.merge("R2_BACKUP_BUCKET" => nil))

    expect(status).not_to be_success
    expect(err).to include("R2_BACKUP_BUCKET")
    expect(calls).not_to exist
  end

  it "restores a backup into the database given, in one transaction that stops at the first error" do
    sql = "CREATE TABLE shows (id bigint);\n"
    put("midrolo-2026-10-24T030000Z.sql.gz", Zlib.gzip(sql))

    out, err, status = backup("restore", "midrolo-2026-10-24T030000Z.sql.gz", "midrolo_restore_check")
    expect(status).to be_success, err
    expect(out).to include("restored midrolo-2026-10-24T030000Z.sql.gz into midrolo_restore_check")
    expect(dir.join("psql.in").read).to eq(sql)
    expect(calls.read).to include("psql --quiet --no-psqlrc --set ON_ERROR_STOP=1 --single-transaction --output /dev/null --dbname midrolo_restore_check")
  end

  it "lists the backups" do
    put(old)
    out, _err, status = backup("list")
    expect(status).to be_success
    expect(out).to include(old)
  end

  it "is healthy unless the last daily run failed" do
    expect(backup("health").last).to be_success
    dir.join("midrolo-backup-failed").write("")
    expect(backup("health").last).not_to be_success
  end
end
