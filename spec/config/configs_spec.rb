require "rails_helper"

RSpec.describe "App configs" do
  def config(name) = Rails.application.config_for(name)

  it "defines the app name" do
    expect(APP_NAME).to eq("Midrolo")
  end

  it "loads plans" do
    expect(config(:plans).dig(:creator, :price_monthly_usd)).to eq(19)
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
end
