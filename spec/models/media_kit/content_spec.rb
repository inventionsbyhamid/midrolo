require "rails_helper"

RSpec.describe MediaKit::Content do
  let(:show) { create(:show, downloads_per_episode: 20_000, categories: [ "Technology" ], cadence_days: 7, episode_count: 148) }
  let(:kit) { MediaKit.create!(show: show) }
  let(:audience) do
    { "brands" => [ { "id" => "b1", "name" => "Fieldnote Coffee", "affinity" => 0.9 },
                    { "id" => "b2", "name" => "Rival Pods", "affinity" => 0.8 },
                    { "id" => "b3", "name" => "Ledger Pens", "affinity" => 0.7 } ],
      "podcasts" => [ { "id" => "p1", "name" => "Index Fund Mornings" } ],
      "tags" => [ { "id" => "t1", "name" => "Personal finance", "score" => 0.8 } ] }
  end

  def content = described_class.new(kit)

  describe "audience data" do
    it "comes from the show's latest done report, never a running or failed one" do
      create(:report, show: show, status: "done", audience: audience, created_at: 2.days.ago)
      create(:report, show: show, status: "failed", audience: { "tags" => [ { "name" => "Wrong" } ] })
      create(:report, show: show, status: "running")

      expect(content.report.audience).to eq(audience)
      expect(content.taste_tags).to eq([ "Personal finance" ])
    end

    it "is absent without a done report" do
      create(:report, show: show, status: "running")
      expect(content.audience?).to be(false)
      expect([ content.brands, content.taste_tags, content.demographics, content.heatmap ]).to eq([ [], [], nil, nil ])
    end

    it "leaves out the brands the owner hid, but lists them all for the editor" do
      create(:report, show: show, status: "done", audience: audience)
      kit.update!(hidden_brand_ids: [ "b2" ])

      expect(content.brands.map { |b| b["name"] }).to eq([ "Fieldnote Coffee", "Ledger Pens" ])
      expect(content.brands(include_hidden: true).map { |b| b["id"] }).to eq(%w[b1 b2 b3])
    end
  end

  describe "#rates" do
    it "uses the rate card's suggestion where the owner set nothing" do
      rates = content.rates
      expect([ rates.midroll, rates.preroll, rates.postroll, rates.bundle4 ]).to eq([ 750, 600, 375, 2700 ])
      expect(rates.custom?).to be(false)
    end

    it "takes the owner's figures and prices the bundle from their mid-roll" do
      kit.update!(rate_card_overrides: { "midroll" => "1000", "postroll" => "300" })
      rates = content.rates

      expect([ rates.midroll, rates.preroll, rates.postroll, rates.bundle4 ]).to eq([ 1000, 600, 300, 3600 ])
      expect(rates.custom?).to be(true)
    end
  end

  describe "#contact" do
    it "mails the contact email the owner chose" do
      show.update!(contact_email: "sponsors@example.com", owner_email: "owner@example.com")
      expect(content.contact_href).to eq("mailto:sponsors@example.com")
    end

    it "never falls back to the feed's owner address" do
      show.update!(contact_email: nil, owner_email: "owner@example.com", website: "https://show.example.com")
      expect(content.contact_href).to eq("https://show.example.com")

      show.update!(website: nil)
      expect(content.contact_href).to be_nil
    end

    it "ignores a website that isn't http(s)" do
      show.update_columns(website: "javascript:alert(1)")
      expect(content.contact_href).to be_nil
    end
  end

  it "describes the publishing cadence in words" do
    expect(content.cadence).to eq("Weekly")
    show.update!(cadence_days: 1)
    expect(content.cadence).to eq("Daily")
    show.update!(cadence_days: 14)
    expect(content.cadence).to eq("Every 2 weeks")
    show.update!(cadence_days: 30)
    expect(content.cadence).to eq("Monthly")
    show.update!(cadence_days: 4)
    expect(content.cadence).to eq("Every 4 days")
    show.update!(cadence_days: nil)
    expect(content.cadence).to be_nil
  end
end
