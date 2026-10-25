require "rails_helper"

RSpec.describe Research::Places do
  it "names the nearest metro within 75 km of a point (R106)" do
    expect(described_class.name_for(30.30, -97.70)).to eq("Austin")
    expect(described_class.name_for(40.75, -73.99)).to eq("New York")
    expect(described_class.name_for(51.50, -0.10)).to eq("London")
    expect(described_class.name_for(-33.90, 151.20)).to eq("Sydney")
    expect(described_class.name_for(19.10, 72.90)).to eq("Mumbai")
  end

  it "measures the 75 km on the ground and names nothing farther away" do
    expect(described_class.name_for(30.27 + 0.63, -97.74)).to eq("Austin") # about 70 km north
    expect(described_class.name_for(30.27 + 0.72, -97.74)).to be_nil       # about 80 km north
    expect(described_class.name_for(0.0, -30.0)).to be_nil
  end

  it "prefers the report's own country, so a Detroit cell of a US report is never Windsor (Task 20)" do
    cell = [ 42.31, -83.035 ] # across the river from Detroit, nearer Windsor's row
    expect(described_class.name_for(*cell, country: "US")).to eq("Detroit")
    expect(described_class.name_for(*cell, country: "CA")).to eq("Windsor")
    expect(described_class.name_for(*cell)).to eq("Windsor")
    expect(described_class.name_for(*cell, country: "us")).to eq("Detroit")
  end

  it "falls back to the nearest metro anywhere when none of the country's is within 75 km" do
    expect(described_class.name_for(51.50, -0.10, country: "US")).to eq("London")
    expect(described_class.name_for(51.50, -0.10, country: "ZZ")).to eq("London")
  end

  it "keeps a small table of about 150 metros, covering every fallback metro and the Fake's" do
    metros = described_class.metros
    expect(metros.size).to be_between(140, 180)
    expect(metros).to all(have_attributes(name: be_present, lat: be_between(-90, 90), lng: be_between(-180, 180)))

    fallback = Rails.application.config_for(:geo).values.flatten
    fake = YAML.load_file(Rails.root.join("config/fake_taste_catalog.yml")).fetch("metros").keys
    expect(metros.map(&:name)).to include(*fallback, *fake)
  end
end
