require "rails_helper"

# compose.yml, the production stack on ioflood (R37, R79, R115; docs/deploy.md), read as YAML: Docker isn't on the
# Mac, and nothing here may build or start the stack. ioflood is a shared production server, so the stack publishes no
# host port, keeps every name under midrolo-, and only midrolo-web joins Coolify's network, where Traefik routes
# midrolo.com to it. Compose makes each service's key a DNS alias on every network the service joins, so the keys are
# midrolo- names too: a bare "web" on the shared coolify network could answer another app's lookups.
RSpec.describe "The compose stack" do
  let(:compose) { YAML.load_file(Rails.root.join("compose.yml")) } # no anchors: plain YAML, as the brief checks it
  let(:services) { compose.fetch("services") }
  let(:labels) { services.dig("midrolo-web", "labels") }

  def label(key) = labels.find { |entry| entry.start_with?("#{key}=") }&.delete_prefix("#{key}=")

  it "runs web, jobs, db and backup, every name (and so every DNS alias) under midrolo-" do
    expect(compose["name"]).to eq("midrolo")
    expect(services.keys).to eq(%w[midrolo-web midrolo-jobs midrolo-db midrolo-backup])
    services.each { |key, service| expect(service["container_name"]).to eq(key) }
    expect(compose["volumes"].values.map { |volume| volume["name"] }).to eq(%w[midrolo-db midrolo-backup-state])
    expect(compose.dig("networks", "midrolo", "name")).to eq("midrolo-net")
    expect(services.values.filter_map { |service| service["image"] }).to eq(
      [ "midrolo-app:latest", "midrolo-app:latest", "postgres:16", "midrolo-backup:latest" ]
    )
  end

  it "publishes no port on the host, adds no alias of its own, and shares no network but Coolify's" do
    services.each do |name, service|
      expect(service.keys).not_to include("ports", "network_mode", "hostname"), name
      expect(service["networks"]).to be_an(Array).and(include("midrolo")), name # the list form: no extra aliases
    end
    expect(services.select { |_, service| service["networks"].include?("coolify") }.keys).to eq([ "midrolo-web" ])
    expect(compose.dig("networks", "coolify")).to eq("external" => true)
  end

  it "starts each service after the ones it needs, by their midrolo- names" do
    expect(services.transform_values { |service| service.fetch("depends_on", {}).keys }).to eq(
      "midrolo-web" => [ "midrolo-db" ], "midrolo-jobs" => [ "midrolo-web" ], "midrolo-db" => [],
      "midrolo-backup" => [ "midrolo-db" ]
    )
  end

  it "limits, health checks and restarts every service" do
    services.each do |name, service|
      expect(service.dig("deploy", "resources", "limits")).to eq("cpus" => "2", "memory" => "2G"), name
      expect(service["pids_limit"]).to eq(512), name
      expect(service["restart"]).to eq("unless-stopped"), name
      expect(service.dig("healthcheck", "test")).to be_present, name
    end
  end

  it "routes midrolo.com to Thruster on port 80 through Traefik, with https and www sent to the apex" do
    expect(label("traefik.enable")).to eq("true")
    expect(label("traefik.docker.network")).to eq("coolify")
    expect(label("traefik.http.services.midrolo-web.loadbalancer.server.port")).to eq("80")

    expect(label("traefik.http.routers.midrolo-https.rule")).to eq("Host(`midrolo.com`)")
    expect(label("traefik.http.routers.midrolo-https.entrypoints")).to eq("https")
    expect(label("traefik.http.routers.midrolo-https.tls.certresolver")).to eq("letsencrypt")

    expect(label("traefik.http.routers.midrolo-http.rule")).to eq("Host(`midrolo.com`) || Host(`www.midrolo.com`)")
    expect(label("traefik.http.routers.midrolo-http.middlewares")).to eq("midrolo-https-redirect")
    expect(label("traefik.http.middlewares.midrolo-https-redirect.redirectscheme.scheme")).to eq("https")

    expect(label("traefik.http.routers.midrolo-www.rule")).to eq("Host(`www.midrolo.com`)")
    expect(label("traefik.http.routers.midrolo-www.tls.certresolver")).to eq("letsencrypt")
    expect(label("traefik.http.routers.midrolo-www.middlewares")).to eq("midrolo-www-redirect")
    regex = label("traefik.http.middlewares.midrolo-www-redirect.redirectregex.regex")
    expect(Regexp.new(regex).match("https://www.midrolo.com/pricing?x=1")[1]).to eq("pricing?x=1")
    # $$ is compose's escape for $, so Traefik gets ${1}.
    expect(label("traefik.http.middlewares.midrolo-www-redirect.redirectregex.replacement")).to eq("https://midrolo.com/$${1}")
  end

  it "names every router, service and middleware midrolo-, so no other stack's can clash" do
    names = labels.filter_map { |entry| entry[/\Atraefik\.http\.(?:routers|services|middlewares)\.([^.]+)\./, 1] }.uniq
    expect(names).to match_array(%w[midrolo-http midrolo-https midrolo-www midrolo-web midrolo-https-redirect midrolo-www-redirect])
    references = labels.filter_map { |entry| entry[/\.(?:service|middlewares)=(.+)\z/, 1] }
    expect(references).to all(start_with("midrolo-"))
  end

  it "runs every queue in the jobs container with a connection for each job thread, plus 2, and none in Puma" do
    queue = YAML.load(ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true)
    job_threads = queue.dig("production", "workers").sum { |worker| worker["threads"] * worker["processes"].to_i }

    expect(services.dig("midrolo-jobs", "command")).to eq([ "./bin/jobs" ])
    expect(services.dig("midrolo-jobs", "environment", "RAILS_MAX_THREADS").to_i).to be >= job_threads + 2
    # Its health check waits for every worker's heartbeat.
    workers = queue.dig("production", "workers").sum { |worker| worker["processes"].to_i }
    expect(services.dig("midrolo-jobs", "healthcheck", "test").join(" ")).to include("count(*) >= #{workers} FROM solid_queue_processes")
    expect(services.dig("midrolo-web", "environment")).not_to have_key("SOLID_QUEUE_IN_PUMA")
    expect(services.dig("midrolo-jobs", "pull_policy")).to eq("never") # the image web built, never one from a registry
  end

  it "keeps the database on its own volume, reached as midrolo-db by the app and the backups" do
    db = services["midrolo-db"]
    expect(db["volumes"]).to eq([ "midrolo-db:/var/lib/postgresql/data" ])
    expect(db.dig("environment", "POSTGRES_USER")).to eq("midrolo")
    expect(%w[midrolo-web midrolo-jobs].map { |name| services.dig(name, "environment", "DB_HOST") }).to all(eq("midrolo-db"))
    expect(services.dig("midrolo-backup", "environment", "PGHOST")).to eq("midrolo-db")
  end

  it "backs up nightly with bin/backup on a token of its own, flagged unhealthy until a failed run is followed by a good one" do
    backup = services["midrolo-backup"]
    expect(backup["command"]).to eq(%w[backup daily])
    expect(backup.dig("healthcheck", "test")).to eq(%w[CMD backup health])
    expect(backup["environment"].keys).to include("R2_BACKUP_BUCKET", "BACKUP_R2_ACCESS_KEY_ID", "BACKUP_R2_SECRET_ACCESS_KEY", "PGPASSWORD")
    expect(backup["environment"].keys).not_to include("R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_BUCKET") # the app's
    expect(backup["volumes"]).to eq([ "midrolo-backup-state:#{backup.dig('environment', 'BACKUP_STATE_DIR')}" ])
    expect(Rails.root.join("Dockerfile.backup").read).to include("FROM docker.io/library/postgres:16", "COPY bin/backup")
  end

  it "is what docs/deploy.md tells the operator to run: every docker compose command names a service here" do
    commands = Rails.root.join("docs/deploy.md").read.scan(/docker compose (exec|run|logs|stop|start|ps|build|restart)([^\n`]*)/)
    named = commands.flat_map do |verb, rest|
      words = rest.split.reject { |word| word.start_with?("-") || word.match?(/\A\d+\z/) }
      %w[exec run logs].include?(verb) ? words.first(1) : words.take_while { |word| word.match?(/\A[a-z][\w-]*\z/) }
    end.uniq
    expect(named).not_to be_empty
    expect(named - services.keys).to be_empty
  end
end
