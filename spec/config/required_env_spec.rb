require "rails_helper"

# What production can't start without (Task 21): config/environments/production.rb runs RequiredEnv.check! at boot.
# spec/requests/production_config_spec.rb boots production with and without them.
RSpec.describe RequiredEnv do
  let(:complete) do
    { "SECRET_KEY_BASE" => "s", "MIDROLO_DATABASE_PASSWORD" => "p", "APP_URL" => "https://midrolo.com",
      "RESEND_API_KEY" => "re_1", "R2_ACCOUNT_ID" => "a", "R2_ACCESS_KEY_ID" => "k", "R2_SECRET_ACCESS_KEY" => "s",
      "R2_BUCKET" => "b", "QLOO_API_KEY" => "q", "PODCAST_INDEX_KEY" => "k", "PODCAST_INDEX_SECRET" => "s" }
  end

  def names(env) = described_class.missing(env).map(&:first)

  it "passes when every variable is set" do
    expect(names(complete)).to be_empty
    expect { described_class.check!(complete) }.not_to raise_error
  end

  it "counts a blank value as missing" do
    expect(names(complete.merge("RESEND_API_KEY" => "  ", "R2_BUCKET" => ""))).to eq([ %w[RESEND_API_KEY], %w[R2_BUCKET] ])
  end

  it "takes either of a pair: RAILS_MASTER_KEY for SECRET_KEY_BASE, DATABASE_URL for the password" do
    env = complete.except("SECRET_KEY_BASE", "MIDROLO_DATABASE_PASSWORD")
    expect(names(env)).to eq([ %w[SECRET_KEY_BASE RAILS_MASTER_KEY], %w[MIDROLO_DATABASE_PASSWORD DATABASE_URL] ])
    expect(names(env.merge("RAILS_MASTER_KEY" => "m", "DATABASE_URL" => "postgres://db/x"))).to be_empty
  end

  it "stops with every missing variable named, and what it is for" do
    env = complete.except("APP_URL", "R2_SECRET_ACCESS_KEY", "QLOO_API_KEY")
    expect { described_class.check!(env) }.to raise_error(RequiredEnv::Missing) { |error|
      expect(error.message.lines.first).to eq("Production can't start until these environment variables are set right:\n")
      expect(error.message).to include("  APP_URL: ", "  R2_SECRET_ACCESS_KEY: ", "  QLOO_API_KEY: ", ".env.example")
      expect(error.message).not_to include("RESEND_API_KEY")
    }
  end

  it "stops when APP_URL isn't an absolute http(s) address, naming APP_URL but never its value" do
    [ "example.org", "ftp://example.org", "http:///no-host", "http://exa mple.org", "javascript:alert(1)", "/pricing" ].each do |value|
      expect { described_class.check!(complete.merge("APP_URL" => value)) }.to raise_error(RequiredEnv::Missing) { |error|
        expect(error.message).to include("  APP_URL: isn't an absolute http(s) address")
        expect(error.message).not_to include(value)
      }
    end
  end

  it "takes an absolute http(s) APP_URL, and gives production its parts" do
    %w[https://midrolo.com http://localhost:3100 https://midrolo.com/].each do |value|
      expect { described_class.check!(complete.merge("APP_URL" => value)) }.not_to raise_error
    end
    expect(described_class.app_uri("https://midrolo.com")).to have_attributes(scheme: "https", host: "midrolo.com")
    expect(described_class.app_uri("midrolo.com")).to be_nil
    expect(described_class.app_uri(nil)).to be_nil
  end

  it "leaves the optional keys alone: admin, error mail, LLM, sign in and billing" do
    expect(described_class::VARIABLES.flat_map(&:first)).not_to include(
      "ADMIN_USERNAME", "ADMIN_PASSWORD", "ADMIN_EMAIL", "OPENROUTER_API_KEY", "ANTHROPIC_API_KEY", "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET",
      "DODO_API_KEY", "DODO_WEBHOOK_SECRET", "R2_BACKUP_BUCKET"
    )
  end
end
