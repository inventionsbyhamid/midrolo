require "rails_helper"

# The whole agent on the Fake taste provider (config/fake_taste_catalog.yml) and fake LLM mode: no network, no Qloo
# data. Sponsor history (lane L2) is stubbed with rows shaped as Sponsors::History documents them.
RSpec.describe FitSearch::Run do
  let(:user) { create(:user) }
  let(:brand) { create(:brand, name: "Notion", domain: "notion.so") }
  let(:search) { create(:fit_search, user: user, brand: brand, query: "Notion", website: "notion.so", categories: [], budget_cents: 50_000) }

  def fake_id(name) = "fake:podcast:#{name.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')}"

  def podcast(name, **attrs) = create(:podcast, :active, title: name, qloo_entity_id: fake_id(name), categories: [ "Business" ], **attrs)

  def history(podcast, episodes) = { podcast: podcast, first_seen: 3.months.ago, last_seen: 1.week.ago,
                                     episodes_count: episodes, codes: [ "NOTES" ], evidence: "Brought to you by" }

  def steps = search.agent_steps.reload.to_a

  before do
    allow(Sponsors::History).to receive(:for_brand).and_return([])
  end

  it "runs every step, ranks Qloo's podcasts with proof, price and trust, and saves the results" do
    ledger = podcast("The Founder's Ledger", open_to_sponsors: true, claimed_at: 1.day.ago, min_price_cents: 40_000,
                                             downloads_per_episode: 2400, downloads_trust: "verified")
    podcast("Deep Work Daily")
    removed = podcast("Code & Coffee Weekly", status: "removed")
    todoist = create(:brand, name: "Todoist", domain: "todoist.com")
    allow(Sponsors::History).to receive(:for_brand).with(todoist).and_return([ history(ledger, 4) ])

    described_class.call(search)
    search.reload

    expect(search).to have_attributes(status: "done", qloo_brand_entity_id: "fake:brand:notion", error_message: nil)
    expect(search.finished_at).to be_present
    expect(search.categories).to eq([ "Productivity" ])
    expect(steps.map(&:tool)).to eq(%w[find_brand qloo_podcasts category_scores proof price_trust rank summary])
    expect(steps.map(&:status)).to all(eq("ok").or(eq("warning")))
    expect(steps.first.output_summary).to start_with("Found Notion on Qloo in Productivity")
    expect(search.taste_calls).to be_between(1, described_class::HARD_TASTE_CALLS)

    results = search.results.includes(:podcast).to_a
    expect(results.map(&:podcast)).to include(ledger)
    expect(results.map(&:podcast)).not_to include(removed)
    expect(results.map(&:score)).to eq(results.map(&:score).sort.reverse)
    expect(results.map(&:position)).to eq((1..results.size).to_a)

    top = results.find { |r| r.podcast == ledger }
    expect(top.price_fit).to eq("within")
    expect(top.reasons.first).to match(/\AQloo ranks it #\d+ of \d+ podcasts for Notion's customers\.\z/)
    expect(top.proof["brands"]).to eq([ { "brand" => "Todoist", "slug" => todoist.slug, "relation" => "category", "episodes" => 4,
                                          "last_seen" => 1.week.ago.to_date.iso8601 } ])
    expect(top.proof["points"]).to include("proof" => 12, "price" => 15, "trust" => 10)
    expect(top.score).to eq(top.proof["points"].values.sum)

    expect(brand.reload.qloo_entity_id).to eq("fake:brand:notion")
    expect(brand.qloo_profile).to include("entity_id" => "fake:brand:notion", "name" => "Notion", "categories" => [ "Productivity" ])
    expect(brand.categories).to eq([ "Productivity" ])
    expect(search.summary.lines.size).to eq(3)
    expect(search.summary).not_to match(/[\u2014\u2013]/)
  end

  it "scores catalog shows in the brand's categories that Qloo didn't list, and open shows Qloo doesn't know" do
    extra = create(:podcast, :active, title: "Spreadsheet Stories", qloo_entity_id: "fake:podcast:not-in-the-fake-list",
                                      categories: [ "Technology" ])
    open = create(:podcast, :active, title: "Main Street Money", categories: [ "Entrepreneurship" ], open_to_sponsors: true,
                                     claimed_at: 1.day.ago)
    elsewhere = create(:podcast, :active, title: "Giggle Hour", qloo_entity_id: "fake:podcast:giggle-hour", categories: [ "Comedy" ])

    described_class.call(search)

    results = search.reload.results.index_by(&:podcast_id)
    expect(results[extra.id].taste_score).to be_between(0.2, 0.95)
    expect(results[extra.id].reasons).to include(a_string_starting_with("Qloo taste match for Notion's customers"))
    expect(results[extra.id].reasons).to include("In your categories: Technology.")
    expect(results[open.id].taste_score).to be_nil
    expect(results[open.id].reasons).to include("No Qloo taste data for this show yet.")
    expect(results[open.id].proof["points"]["taste"]).to eq(10)
    expect(results).not_to have_key(elsewhere.id)
  end

  it "reuses the brand's Qloo profile from the last 7 days instead of looking it up again" do
    described_class.call(search)
    again = create(:fit_search, user: user, brand: brand, query: "Notion")
    allow(Taste::Provider.current).to receive(:search).and_call_original

    described_class.call(again)

    expect(Taste::Provider.current).not_to have_received(:search)
    expect(again.reload.agent_steps.first.output_summary).to start_with("Reused Notion's Qloo profile from")
    expect(again.qloo_brand_entity_id).to eq("fake:brand:notion")
  end

  it "keeps a client's Qloo profile off the agency's own brand" do
    agency = create(:brand, name: "Acme Agency", domain: "acme.example")
    client = create(:brand, name: "Notion")
    for_client = create(:fit_search, user: user, brand: agency, query: "Notion", website: "acme.example")

    described_class.call(for_client)

    expect(agency.reload.qloo_profile).to eq({})
    expect(agency.qloo_entity_id).to be_nil
    expect(client.reload.qloo_profile["entity_id"]).to eq("fake:brand:notion")
  end

  it "uses the brand's categories as Qloo's signal when Qloo doesn't know the brand by name" do
    podcast("Index Fund Mornings")
    unknown = create(:fit_search, user: user, brand: create(:brand, name: "Zzyzx Ledgerworks"), query: "Zzyzx Ledgerworks",
                                  categories: [ "Finance" ])
    taste = Taste::Provider.current
    allow(taste).to receive(:recommend).and_call_original

    described_class.call(unknown)

    expect(unknown.reload.status).to eq("done")
    expect(unknown.qloo_brand_entity_id).to be_nil
    expect(unknown.agent_steps.first).to have_attributes(status: "warning")
    expect(unknown.agent_steps.first.output_summary).to include("Qloo doesn't know Zzyzx Ledgerworks by name")
    expect(taste).to have_received(:recommend).with(hash_including(type: :podcast, tag_ids: [ "urn:tag:genre:brand:finance" ]))
    expect(unknown.results.first.reasons.first).to include("people into Finance")
  end

  it "adds the top Qloo podcasts the catalog lacks through the one matcher" do
    added = create(:podcast, title: "Added From Qloo", status: "pending", categories: [])
    asked = []
    allow(Catalog::QlooMatch).to receive(:call) do |entity|
      asked << entity
      added if asked.size == 1
    end

    described_class.call(search)

    expect(asked.size).to eq(described_class::LAZY_ADD_LIMIT) # the fake catalog has 16 podcasts, none in this catalog
    expect(added.reload.qloo_entity_id).to eq(asked.first.id)
    expect(search.reload.results.map(&:podcast_id)).to include(added.id)
    expect(search.agent_steps.find_by(tool: "qloo_podcasts").output_summary).to include("0 in the catalog, 1 added now")
  end

  it "leaves a show the matcher fails on out, and finishes" do
    allow(Catalog::QlooMatch).to receive(:call).and_raise(Podcasts::Directory::Unavailable, "down")

    described_class.call(search)

    expect(search.reload.status).to eq("done")
    expect(search.agent_steps.find_by(tool: "qloo_podcasts").output_summary).to include("Some shows couldn't be added to the catalog just now.")
  end

  it "finishes with a warning when an optional Qloo call fails" do
    podcast("The Founder's Ledger")
    create(:podcast, :active, qloo_entity_id: "fake:podcast:somewhere", categories: [ "Technology" ])
    allow(Taste::Provider.current).to receive(:affinity_for).and_raise(Taste::Unavailable, "Qloo /v2/insights returned HTTP 503")

    described_class.call(search)

    expect(search.reload.status).to eq("done")
    step = search.agent_steps.find_by(tool: "category_scores")
    expect(step).to have_attributes(status: "warning")
    expect(step.output_summary).to include("Taste scores skipped: Qloo is unavailable right now.")
    expect(step.output_summary).not_to include("503")
  end

  it "fails the search, and counts toward pausing runs, when Qloo rejects the key" do
    allow(Taste::Provider.current).to receive(:search).and_raise(Taste::AuthError, "Qloo /search returned HTTP 401")
    allow(AppSettings).to receive(:record_taste_auth_failure!)

    described_class.call(search)

    expect(search.reload).to have_attributes(status: "failed", error_message: described_class::FAILURE_MESSAGE)
    expect(search.agent_steps.first.status).to eq("error")
    expect(AppSettings).to have_received(:record_taste_auth_failure!)
  end

  it "fails as busy when the call guard refuses, without reporting an error" do
    allow(Taste::Provider.current).to receive(:search).and_raise(Taste::CallCapReached, "cap")
    allow(Rails.error).to receive(:report)

    described_class.call(search)

    expect(search.reload).to have_attributes(status: "failed", error_message: described_class::BUSY_MESSAGE)
    expect(Rails.error).not_to have_received(:report)
  end

  it "says when the free share of Qloo calls is spent" do
    allow(Taste::Provider.current).to receive(:search).and_raise(Taste::FreeShareSpent, "share")

    described_class.call(search)

    expect(search.reload.error_message).to eq(described_class::FREE_BUSY_MESSAGE)
  end

  it "ends done with no results and a plain brief when nothing fits" do
    described_class.call(search)

    expect(search.reload.status).to eq("done")
    expect(search.results).to be_empty
    expect(search.summary).to start_with("No podcasts in the catalog fit Notion yet")
  end

  it "never resolves a competitor name into a new brand" do
    search
    expect { described_class.call(search) }.not_to change(Brand, :count)
  end
end
