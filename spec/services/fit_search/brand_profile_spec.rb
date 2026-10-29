require "rails_helper"

RSpec.describe FitSearch::BrandProfile do
  def entity(properties: {}, tags: [])
    Taste::Entity.new(id: "Q-BRAND", name: "Fieldnote Coffee", type: :brand, popularity: 0.4, affinity: nil, image_url: nil,
                      description: nil, website: "https://fieldnote.example", tags: tags, properties: properties)
  end

  it "keeps the entity, its tags, categories and the brand data Qloo lists, in any of the shapes it may send" do
    tags = [ Taste::Tag.new(id: "urn:tag:genre:brand:food_and_beverage", name: "Food and Beverage", type: "urn:tag:genre:brand", score: nil) ]
    props = { "competitive_set" => [ { "name" => "Trade Coffee", "entity_id" => "Q-TRADE" }, { "name" => "Fieldnote Coffee", "entity_id" => "Q-BRAND" } ],
              "complementary_brands" => "Our Place, Graza; ", "industries" => [ "Coffee", "Coffee" ] }

    profile = described_class.from_entity(entity(properties: props, tags: tags), now: Time.utc(2026, 10, 30, 12))

    expect(profile).to include("entity_id" => "Q-BRAND", "name" => "Fieldnote Coffee", "fetched_at" => "2026-10-30T12:00:00Z",
                               "categories" => [ "Food & Beverage" ], "industries" => [ "Coffee" ],
                               "competitors" => [ { "name" => "Trade Coffee", "id" => "Q-TRADE" } ],
                               "complementary" => [ { "name" => "Our Place" }, { "name" => "Graza" } ])
    expect(profile["tags"]).to eq([ { "id" => "urn:tag:genre:brand:food_and_beverage", "name" => "Food and Beverage", "type" => "urn:tag:genre:brand" } ])
    expect(described_class.tags(profile).map(&:name)).to eq([ "Food and Beverage" ])
  end

  it "reads missing brand data as empty lists" do
    profile = described_class.from_entity(entity)

    expect(profile.values_at("competitors", "complementary", "industries", "categories")).to eq([ [], [], [], [] ])
  end
end
