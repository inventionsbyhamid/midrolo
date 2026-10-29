require "rails_helper"

RSpec.describe CatalogHelper do
  it "badges a status in its tone" do
    expect(helper.catalog_status_badge("failed")).to include("badge-danger", "Failed")
    expect(helper.catalog_status_badge("active")).to include("badge-success")
  end

  it "puts a feed error code in words" do
    expect(helper.catalog_error_label("feed_timeout")).to eq("Feed took too long")
    expect(helper.catalog_error_label("feed_http_418")).to eq("Feed answered HTTP 418")
    expect(helper.catalog_error_label("something_new")).to eq("Something new")
  end

  it "names the hosting provider and the measurement prefixes" do
    podcast = build(:podcast, hosting_provider: "transistor", measurement: %w[op3 chartable unknown])
    expect(helper.catalog_hosting_name(podcast)).to eq("Transistor")
    expect(helper.catalog_measurement_names(podcast)).to eq([ "OP3", "Chartable" ])
  end
end
