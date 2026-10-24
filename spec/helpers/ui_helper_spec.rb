require "rails_helper"

RSpec.describe UiHelper do
  def fragment(html) = Nokogiri::HTML5.fragment(html)

  def classes(node) = node["class"].split

  describe "#ui_button" do
    it "renders a link with the secondary classes when given an href" do
      link = fragment(helper.ui_button("Go", "/x", variant: :secondary)).at_css("a")

      expect(link["href"]).to eq("/x")
      expect(link.text).to eq("Go")
      expect(classes(link)).to include("btn", "btn-secondary", "btn-md")
      expect(classes(link)).not_to include("btn-primary")
    end

    it "renders a button element when no href is given" do
      button = fragment(helper.ui_button("Run report", type: "submit", size: :lg)).at_css("button")

      expect(button["type"]).to eq("submit")
      expect(button.text).to eq("Run report")
      expect(classes(button)).to include("btn", "btn-primary", "btn-lg")
    end

    it "merges extra classes and passes other attributes through" do
      link = fragment(helper.ui_button("Delete", "/x", variant: :danger, class: "w-full", data: { turbo_method: :delete })).at_css("a")

      expect(classes(link)).to include("btn", "btn-danger", "w-full")
      expect(link["data-turbo-method"]).to eq("delete")
    end

    it "rejects an unknown variant" do
      expect { helper.ui_button("Go", "/x", variant: :loud) }.to raise_error(KeyError)
    end
  end

  describe "#ui_badge" do
    it "renders the text with its tone class" do
      badge = fragment(helper.ui_badge("Easy yes", tone: :success)).at_css("span")

      expect(badge.text).to eq("Easy yes")
      expect(classes(badge)).to include("badge", "badge-success")
    end
  end

  describe "#ui_meter" do
    it "exposes a 0 to 1 value as a 0 to 100 meter" do
      html = helper.ui_meter(0.82, label: "Affinity")
      meter = fragment(html).at_css("[role=meter]")

      expect(html).to include('aria-valuenow="82"')
      expect(meter["aria-valuemin"]).to eq("0")
      expect(meter["aria-valuemax"]).to eq("100")
      expect(meter["aria-label"]).to eq("Affinity")
      expect(meter["aria-valuetext"]).to eq("0.82")
      expect(meter.text).to include("Affinity", "0.82")
    end

    it "lights one of 20 segments per 5 points" do
      meter = fragment(helper.ui_meter(0.82, label: "Affinity"))

      expect(meter.css(".meter-seg").size).to eq(20)
      expect(meter.css(".meter-seg-on").size).to eq(16)
    end

    it "clamps values outside 0 to 1" do
      expect(helper.ui_meter(1.4, label: "Fit")).to include('aria-valuenow="100"')
      expect(helper.ui_meter(-0.2, label: "Fit")).to include('aria-valuenow="0"')
      expect(helper.ui_meter(nil, label: "Fit")).to include('aria-valuenow="0"')
    end

    it "shows custom value text and can hide the label visually" do
      meter = fragment(helper.ui_meter(0.91, label: "Fit score", value_text: "91", show_label: false)).at_css("[role=meter]")

      expect(meter["aria-valuetext"]).to eq("91")
      expect(meter.at_css(".meter-label")).to be_nil
      expect(meter.at_css(".meter-value").text).to eq("91")
    end
  end

  describe "#demo_mode?" do
    around do |example|
      original = Rails.configuration.x.demo_mode
      example.run
    ensure
      Rails.configuration.x.demo_mode = original
    end

    it "is false when demo mode is not configured" do
      hide_const("DemoMode")
      expect(helper.demo_mode?).to be(false)
    end

    it "reads Rails.configuration.x.demo_mode when DemoMode is not defined" do
      hide_const("DemoMode")
      Rails.configuration.x.demo_mode = true

      expect(helper.demo_mode?).to be(true)
    end

    it "defers to DemoMode.active? once DemoMode is defined" do
      Rails.configuration.x.demo_mode = false
      stub_const("DemoMode", Module.new { def self.active? = true })

      expect(helper.demo_mode?).to be(true)
    end
  end
end
