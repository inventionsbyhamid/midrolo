require "rails_helper"

RSpec.describe Matching::SimilarShows do
  let(:show) { create(:show, title: "The Founder's Ledger") }
  let(:report) { create(:report, show: show, kind: "agent", status: "done") }
  let(:mornings) { create(:podcast, :active, title: "Index Fund Mornings") }
  let(:dispatch) { create(:podcast, :active, title: "Dollar Dispatch") }
  let(:notion) { create(:brand, name: "Notion", qloo_entity_id: "q-notion") }
  let(:ramp) { create(:brand, name: "Ramp") }

  def entry(name, podcast = nil, score: 0.8) = { "qloo_entity_id" => "q-#{name.parameterize}", "name" => name, "score" => score, "podcast_id" => podcast&.id }

  def mention(brand, podcast, at)
    create(:sponsor_mention, brand: brand, episode: create(:episode, podcast: podcast, published_at: at))
  end

  def similar_for(*entries)
    report.update!(similar_podcasts: entries)
    described_class.for(report.reload)
  end

  it "lists every similar show in Qloo's order, with its catalog podcast and the brands seen sponsoring it" do
    mention(ramp, mornings, 3.days.ago)
    mention(notion, mornings, 1.day.ago)
    mention(notion, dispatch, 2.days.ago)
    mention(notion, dispatch, 5.days.ago)

    similar = similar_for(entry("Index Fund Mornings", mornings), entry("Not In The Catalog"), entry("Dollar Dispatch", dispatch))

    expect(similar.items.map(&:name)).to eq([ "Index Fund Mornings", "Not In The Catalog", "Dollar Dispatch" ])
    expect(similar.items.map(&:podcast)).to eq([ mornings, nil, dispatch ])
    expect(similar.items.first.brands).to eq([ notion, ramp ]) # the latest first
    expect(similar.items.first.score).to eq(0.8)
    expect(similar.items.second.brands).to eq([])

    notion_row, ramp_row = similar.sponsors
    expect(notion_row).to have_attributes(brand: notion, podcasts: [ mornings, dispatch ], episodes: 3)
    expect(notion_row.last_seen).to be_within(1.second).of(1.day.ago)
    expect(ramp_row).to have_attributes(brand: ramp, podcasts: [ mornings ], episodes: 1)
  end

  it "puts a brand's share on its sponsor match, by Qloo entity or by name" do
    mention(notion, mornings, 1.day.ago)
    mention(ramp, dispatch, 1.day.ago)
    similar = similar_for(entry("Index Fund Mornings", mornings), entry("Dollar Dispatch", dispatch))

    by_entity = build(:sponsor_match, report: report, brand_entity_id: "q-notion", name: "Notion Labs")
    by_name = build(:sponsor_match, report: report, brand_entity_id: "q-ramp-somewhere", name: "Ramp")
    stranger = build(:sponsor_match, report: report, brand_entity_id: "q-other", name: "Mercury")

    expect(similar.proof_for(by_entity)).to have_attributes(brand: notion, podcasts: [ mornings ])
    expect(similar.proof_for(by_name)).to have_attributes(brand: ramp, podcasts: [ dispatch ])
    expect(similar.proof_for(stranger)).to be_nil
  end

  it "leaves out the report's own podcast and removed podcasts" do
    gone = create(:podcast, title: "Gone", status: "removed")
    mention(notion, gone, 1.day.ago)
    mention(notion, show.podcast, 1.day.ago)
    similar = similar_for(entry("Gone", gone), entry("The Founder's Ledger", show.podcast))

    expect(similar.items.map(&:podcast)).to eq([ nil, nil ])
    expect(similar.sponsors).to be_empty
  end

  it "reads the catalog in a fixed number of queries, however many shows there are, and none without any" do
    podcasts = create_list(:podcast, 6, :active)
    podcasts.each { |podcast| mention(create(:brand), podcast, 1.day.ago) }
    report.update!(similar_podcasts: podcasts.map { |podcast| entry(podcast.title, podcast) })

    queries = []
    counter = ->(*, payload) { queries << payload[:sql] unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      similar = described_class.for(Report.find(report.id))
      similar.items.each { |item| item.brands.map(&:name) }
      similar.sponsors.map { |sponsor| sponsor.podcasts.map(&:title) }
    end
    expect(queries.size).to be <= 5 # report's show, podcasts (with artwork preloads), mentions, brands

    report.update!(similar_podcasts: [])
    queries.clear
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { described_class.for(report).sponsors }
    expect(queries).to be_empty
  end

  it "ignores entries it can't read" do
    similar = similar_for({ "name" => "" }, "junk", entry("Real Show"))
    expect(similar.items.map(&:name)).to eq([ "Real Show" ])
    expect(similar).to be_any
  end
end
