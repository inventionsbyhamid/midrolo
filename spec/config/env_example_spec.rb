require "rails_helper"

# .env.example (Task 21): every variable the app reads, blank, under a comment saying what it does. Production's
# required ones (lib/required_env.rb, plus the backup bucket) are set lines; the rest are commented out, since a
# NAME= line in .env sets an empty string, which isn't the same as unset for the variables with a default.
RSpec.describe ".env.example" do
  let(:lines) { Rails.root.join(".env.example").read.lines.map(&:chomp) }
  let(:set_names) { lines.grep(/\A[A-Z0-9_]+=/).map { |line| line[/\A[A-Z0-9_]+/] } }
  let(:commented_names) { lines.grep(/\A# [A-Z0-9_]+=\z/).map { |line| line[/[A-Z0-9_]+/] } }

  # Read by Rails, Puma or a rake task's own arguments, or set by the app itself: not for .env.
  let(:internal) do
    %w[BUNDLE_GEMFILE CI EVAL_FILE EVAL_MODE FORCE STEPS FONTCONFIG_FILE PANGOCAIRO_BACKEND PIDFILE PORT
       MY_APP_DATABASE_URL SECRET_KEY_BASE_DUMMY]
  end

  it "holds blank values only" do
    assignments = lines.grep(/\A(# )?[A-Z0-9_]+=/)
    expect(assignments).not_to be_empty
    expect(assignments.reject { |line| line.end_with?("=") }).to be_empty
  end

  it "says what each variable is for, in a comment above it or above its group" do
    lines.each_with_index do |line, index|
      next unless line.match?(/\A(# )?[A-Z0-9_]+=\z/)

      above = lines[...index].reverse.drop_while { |previous| previous.match?(/\A(# )?[A-Z0-9_]+=\z/) }.first.to_s
      expect(above).to start_with("# "), "#{line} has no comment above it"
    end
  end

  it "sets only what production requires, and leaves every optional variable commented out" do
    required = RequiredEnv::VARIABLES.map { |names, _| names.first } + %w[R2_BACKUP_BUCKET]
    alternatives = RequiredEnv::VARIABLES.flat_map { |names, _| names.drop(1) }

    expect(set_names).to match_array(required)
    expect(commented_names).to include(*alternatives)
  end

  it "lists every variable the app reads" do
    sources = Dir[Rails.root.join("{app,config,lib}/**/*.{rb,yml,erb}")].map { |path| File.read(path) }
    read = sources.flat_map { |source| source.scan(/ENV(?:\.fetch\(|\[)"([A-Z0-9_]+)"/).flatten }
    settings = AppSettings::KEYS.map { |key| key.to_s.upcase } # a Setting row, else ENV, else the default

    expect((read + settings).uniq - internal - set_names - commented_names).to be_empty
  end
end
