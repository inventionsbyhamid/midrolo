require "rails_helper"

RSpec.describe "App configs" do
  def config(name) = Rails.application.config_for(name)

  it "defines the app name" do
    expect(APP_NAME).to eq("Midrolo")
  end

  it "loads plans" do
    expect(config(:plans).dig(:creator, :price_monthly_usd)).to eq(19)
  end

  it "maps every price key to a provider product id from ENV" do
    stub_const("ENV", ENV.to_h.merge("DODO_PRODUCT_SPRINT" => "pdt_sprint"))

    expect(config(:plans)[:product_ids]).to eq(creator_monthly: nil, creator_yearly: nil, pro_monthly: nil, pro_yearly: nil,
                                               sprint: "pdt_sprint")
  end

  it "loads scoring weights" do
    expect(config(:scoring)[:weights]).to eq(affinity: 0.55, proven: 0.20, shared_tags: 0.15, category: 0.10)
  end

  it "loads the rate card" do
    expect(config(:rate_card)[:flat_floor_usd]).to eq(25)
  end

  it "loads LLM settings" do
    expect(config(:llm)[:agent][:max_tool_calls]).to eq(40)
  end

  it "loads LLM pricing" do
    expect(config(:llm_pricing).dig(:"claude-opus-5-5", :input)).to eq(4.0)
  end

  it "loads geo fallback metros" do
    geo = config(:geo)
    expect(geo[:US]).to include("New York", "Denver")
    expect(geo.keys).to match_array(%i[US GB CA AU IN])
  end

  it "loads samples" do
    samples = config(:samples)[:samples]
    expect(samples.size).to eq(3)
    expect(samples.map(&:keys).uniq).to eq([ %i[slug directory_id] ])
  end

  it "stores production uploads on Cloudflare R2 from the R2_* variables, and tests on the test service" do
    env = { "R2_ACCOUNT_ID" => "acct", "R2_ACCESS_KEY_ID" => "key", "R2_SECRET_ACCESS_KEY" => "secret", "R2_BUCKET" => "kits" }
    stub_const("ENV", ENV.to_h.merge(env))
    r2 = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))["r2"]

    expect(r2).to include("service" => "S3", "endpoint" => "https://acct.r2.cloudflarestorage.com", "bucket" => "kits",
                          "access_key_id" => "key", "secret_access_key" => "secret", "region" => "auto")
    expect(Rails.configuration.active_storage.service).to eq(:test)
  end

  it "sends mail from MAIL_FROM, defaulting to the app name at midrolo.com" do
    expect(ApplicationMailer.default[:from].call).to eq("Midrolo <hello@midrolo.com>")
  end
end
