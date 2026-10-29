require "rails_helper"

RSpec.describe FitSearch::Categories do
  it "lists the brand categories the category map knows" do
    expect(described_class.names).to include("Finance", "Technology", "Food & Beverage", "Health & Wellness")
    expect(described_class.names).to eq(described_class.names.uniq.sort)
  end

  it "keeps known names as the map writes them and drops the rest" do
    expect(described_class.known([ "food and beverage", "Finance", "Rocketry", "finance" ])).to eq([ "Food & Beverage", "Finance" ])
  end

  it "reads the category map the other way round: the podcast categories a brand category covers" do
    covered = described_class.podcast_categories_for([ "Finance" ])

    expect(covered).to include("Business", "Investing", "Entrepreneurship", "Finance")
    expect(covered).not_to include("Comedy", "True Crime")
    expect(described_class.podcast_categories_for([])).to eq([])
  end

  it "names the Qloo brand tag for a category" do
    expect(described_class.tag_id_for("Food & Beverage")).to eq("urn:tag:genre:brand:food_and_beverage")
    expect(described_class.tag_id_for("Health & Wellness")).to eq("urn:tag:genre:brand:health_and_wellness")
  end

  it "finds the categories among a Qloo entity's tags, sub tags included" do
    tags = [ Taste::Tag.new(id: "urn:tag:genre:brand:food_and_beverage:coffee", name: "Coffee", type: "urn:tag:genre:brand", score: nil),
             Taste::Tag.new(id: "urn:tag:genre:brand:finance", name: "Finance", type: "urn:tag:genre:brand", score: nil),
             Taste::Tag.new(id: "urn:tag:keyword:qloo:budgeting", name: "Budgeting", type: "urn:tag:keyword", score: nil) ]

    expect(described_class.from_tags(tags)).to eq([ "Food & Beverage", "Finance" ])
  end
end
