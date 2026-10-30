require "rails_helper"

# The easy ways in for someone who clones the repo: the dev container (.devcontainer/, GitHub Codespaces) and the one
# command Docker demo (compose.demo.yml). Read as files: Docker may not be where the specs run.
RSpec.describe "The dev container and the Docker demo" do
  def read(path) = Rails.root.join(path).read

  let(:devcontainer) { JSON.parse(read(".devcontainer/devcontainer.json").gsub(%r{^\s*//.*$}, "")) }
  let(:dev_compose) { YAML.load_file(Rails.root.join(".devcontainer/compose.yml")) }
  let(:demo) { YAML.load_file(Rails.root.join("compose.demo.yml")) }

  it "builds on the Ruby in .ruby-version, the bookworm slim image that still has the build headers" do
    expect(read(".devcontainer/Dockerfile")).to include("ARG RUBY_VERSION=#{read('.ruby-version').strip}\n",
                                                        "ruby:${RUBY_VERSION}-slim-bookworm")
  end

  it "sets up with the demo data, then runs bin/dev on port 3100 at every start" do
    expect(devcontainer).to include("dockerComposeFile" => "compose.yml", "service" => "app",
                                    "postCreateCommand" => "bin/setup --skip-server", "forwardPorts" => [ 3100 ])
    expect(devcontainer["postStartCommand"]).to include("bin/dev")
    expect(devcontainer.dig("portsAttributes", "3100", "label")).to eq("Midrolo")
    expect(dev_compose.dig("services", "app", "environment")).to include("RAILS_DEVELOPMENT_HOSTS" => ".app.github.dev,.preview.app.github.dev")
  end

  it "points both at Postgres 16 through libpq's variables, leaving config/database.yml as it is" do
    [ dev_compose, demo ].each do |compose|
      expect(compose.dig("services", "db", "image")).to eq("postgres:16")
      expect(compose.dig("services", "app", "environment")).to include("PGHOST" => "db", "PGUSER" => "postgres")
    end
  end

  it "runs the demo from the dev container's image, seeded on start, on localhost:3100 only" do
    app = demo.dig("services", "app")

    expect(app["build"]).to eq("context" => ".devcontainer", "dockerfile" => "Dockerfile")
    expect(app["command"].last).to start_with("bin/setup --skip-server && ")
    expect(app["ports"]).to eq([ "127.0.0.1:3100:3100" ])
    expect(app["environment"]).to include("BINDING" => "0.0.0.0", "PORT" => "3100")
    expect(app["volumes"]).to include("bundle:/bundle")
  end
end
