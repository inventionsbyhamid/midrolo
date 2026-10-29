require "rails_helper"

# Public sample reports (spec §5.1, R78): the full agent report, read-only, for anyone.
RSpec.describe "Sample reports" do
  let(:owner) { User.find_or_create_by!(email: User::SAMPLES_EMAIL) }
  let(:show) { create(:show, user: owner, title: "The Founder's Ledger", author: "Maya Brandt") }
  let(:seeds) { { "entities" => [ { "id" => "q1", "name" => "Index Fund Mornings", "source" => "Similar on Qloo" } ], "tags" => [] } }
  let!(:report) do
    create(:report, show: show, kind: "agent", status: "done", sample_slug: Samples.slugs[0], spend_bucket: "sample",
                    profile_kind: "direct", seeds: seeds, summary: "People with this show's taste plan their money.")
  end

  before do
    create(:sponsor_match, report: report, name: "Fieldnote Coffee", position: 1)
    create(:agent_step, report: report, label: "Reading your last 15 episodes…", status: "ok")
  end

  def page = Nokogiri::HTML(response.body)

  describe "GET /samples/:slug" do
    it "shows the whole report to a visitor, labelled as a sample, with brand names" do
      get "/samples/#{Samples.slugs[0]}"

      expect(response).to have_http_status(:ok)
      main = page.at_css("main").text.squish
      expect(main).to include("Sample report. Not affiliated with the show.", "The Founder's Ledger", "Fieldnote Coffee",
                              "Index Fund Mornings", "People with this show's taste plan their money.")
      expect(page.at_css("#report_matches")).to be_present
      # A finished report has no steps rail: its steps wait in How we built this, collapsed (R99).
      expect(page.at_css("aside[aria-label='Agent steps']")).to be_nil
      expect(page.at_css("#report_how details:not([open])").text).to include("Reading the last 15 episodes…")
    end

    it "reads in the same order as the owner's report: At a glance, matches, audience, where they are, How we built this" do
      report.update!(audience: { "tags" => [ { "id" => "t1", "name" => "Personal Finance", "score" => 0.9 } ] },
                     heatmap: { "location" => "US", "points" => [ { "lat" => 40.7, "lng" => -74.0, "affinity" => 0.9, "label" => "New York" } ] })
      get "/samples/#{Samples.slugs[0]}"

      ids = page.css(".report-sections > section:not([hidden])").map { |section| section["id"] }
      expect(ids).to eq(%w[report_summary report_matches report_audience report_map report_how])
      glance = page.css("#report_summary ul.glance > li")
      expect(glance.size).to be <= 3
      expect(glance.last.text.squish).to include("Get your own Snapshot")
    end

    it "hides pitch, pipeline and every owner control, even from a signed-in user" do
      sign_in create(:user, :subscribed)
      get "/samples/#{Samples.slugs[0]}"

      body = response.body
      expect(body).not_to include("Write my pitch", "Open pitch", "Pipeline", "Notes &amp; follow up", "Run again",
                                  "Try again", "Run full report")
      expect(page.css("main form")).to be_empty
      expect(page.at_css(".match-actions")).to be_nil
      expect(page.css("main a").map { |a| a["href"] }).not_to include(a_string_matching(%r{\A/(shows/\d+|sponsor_matches)}))
    end

    it "speaks of the show in the third person, never to the reader as its owner" do
      report.update!(audience: { "brands" => [ { "id" => "b1", "name" => "Fieldnote Coffee", "affinity" => 0.9 } ] },
                     demographics: { "age" => { "25_to_29" => 0.4 }, "gender" => { "female" => 0.2 } },
                     heatmap: { "location" => "US", "points" => [ { "lat" => 40.7, "lng" => -74.0, "affinity" => 0.9, "label" => "New York" } ] })
      get "/samples/#{Samples.slugs[0]}"

      titles = page.css(".report-section-title").map { |title| title.text.squish }
      expect(titles).to include("At a glance", "This show's audience", "Where they are")
      # The page's own copy; agent-written text (the summary, step labels, reasons) stays as generated.
      # The next step speaks to the reader about a show of their own ("Get your own Snapshot"), so it isn't counted.
      copy = page.css(".report-section-title, .report-subsection-title, .report-section-note, .profile-banner, .glance-label, " \
                      ".leans-note, .method-list")
                 .map { |node| [ node.text, node["aria-label"] ].join(" ").squish }.join(" ")
      expect(copy).to include("Built from the show on Qloo", "Qloo knows the show", "Modeled from Qloo taste data, not measured.",
                              "What people with this show's listeners' tastes love")
      expect(copy).not_to match(/\byour\b/i)
    end

    it "puts generated text in the third person too: the summary, steps, seed sources, reasons and map label (Task 20)" do
      seeds = { "entities" => [ { "id" => "q0", "name" => "The Founder's Ledger", "source" => Research::Seeds::SHOW_SOURCE } ], "tags" => [] }
      report.update!(seeds: seeds, summary: "Your listeners plan their money.\nPitch Fieldnote Coffee first: your audience loves it.",
                     heatmap: { "location" => "US", "points" => [ { "lat" => 40.7, "lng" => -74.0, "affinity" => 0.9, "label" => "New York" } ] })
      report.sponsor_matches.first.update!(reason: "Fieldnote Coffee fans share your audience's love of Investing.")
      create(:agent_step, report: report, label: "Mapping where your listeners live…", status: "ok",
                          input_summary: "Your show", output_summary: "Your profile is built from topics")

      get "/samples/#{Samples.slugs[0]}"

      doc = page
      doc.css(".glance-next").each(&:remove) # the next step speaks to the reader about a show of their own
      generated = doc.css("#report_summary, #report_how, #report_seeds, .match-reason, #report_map")
                     .map { |node| node.text }.join(" ").squish
      labels = doc.css("[aria-label]").map { |node| node["aria-label"] }.join(" ")
      expect(generated).to include("The listeners plan their money.", "the audience loves it", "The show on Qloo",
                                   "Mapping where the listeners live…", "the audience's love of Investing")
      expect(labels).to include("Heatmap of where people with this audience's tastes live in United States")
      expect("#{generated} #{labels}").not_to match(/\byour\b/i)
    end

    it "has no live stream: a sample never changes while it's open" do
      get "/samples/#{Samples.slugs[0]}"

      expect(page.css("turbo-cable-stream-source")).to be_empty
    end

    it "gives the sample its own title and share tags, with its own share image" do
      get "/samples/#{Samples.slugs[0]}"

      expect(page.at_css("title").text).to eq("The Founder's Ledger sample sponsor report | Midrolo")
      expect_share_tags(page, url: "http://www.example.com/samples/#{Samples.slugs[0]}",
                              image: %r{\Ahttp://www\.example\.com/samples/#{Samples.slugs[0]}/og\.png\?v=\h{12}\z})
      expect(share_tags(page)["og:image:alt"]).to eq([ "Sample sponsor report for The Founder's Ledger" ])
    end

    it "is a 404, not a 500, for an unknown slug" do
      get "/samples/no-such-sample"
      expect(response).to have_http_status(:not_found)
    end

    it "is a 404 for a sample that isn't done yet" do
      report.update!(status: "running")
      get "/samples/#{Samples.slugs[0]}"
      expect(response).to have_http_status(:not_found)
    end

    it "is a 404 for a slug samples.yml no longer lists" do
      report.update!(sample_slug: "retired-sample")
      get "/samples/retired-sample"
      expect(response).to have_http_status(:not_found)
    end
  end

  # R152: the sample's media kit, for visitors with no verified show of their own.
  describe "GET /samples/:slug/kit" do
    before do
      show.update!(website: "https://founders-ledger.example.com")
      report.update!(audience: { "tags" => [ { "id" => "t1", "name" => "Personal Finance", "score" => 0.9 } ],
                                 "brands" => [ { "id" => "b1", "name" => "Fieldnote Coffee", "affinity" => 0.8 } ] })
    end

    it "shows the kit brands would see, labelled as a sample, without the show's contact and unindexed" do
      get "/samples/#{Samples.slugs[0]}/kit"

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Robots-Tag"]).to eq("noindex")
      expect(page.at_css("meta[name='robots']")["content"]).to eq("noindex")
      text = page.at_css("main").text.squish
      expect(text).to include("Sample media kit. Not affiliated with the show.", "The Founder's Ledger", "Personal Finance",
                              "Rates")
      expect(text).not_to include("Work with us", "Preview.")
      expect(page.at_css("a[href='https://founders-ledger.example.com']")).to be_nil
      expect(page.at_css("a[href='/samples/#{Samples.slugs[0]}']")).to be_present
      expect(MediaKit.count).to eq(0)
    end

    it "is linked from the sample report" do
      get "/samples/#{Samples.slugs[0]}"
      expect(page.at_css("a[href='/samples/#{Samples.slugs[0]}/kit']").text).to eq("See the sample media kit")
    end

    it "is a 404 for an unknown or unfinished sample" do
      get "/samples/not-a-sample/kit"
      expect(response).to have_http_status(:not_found)

      report.update!(status: "failed")
      get "/samples/#{Samples.slugs[0]}/kit"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /samples" do
    it "lists the done samples, in samples.yml order" do
      other = create(:show, user: owner, title: "Code & Coffee Weekly")
      create(:report, show: other, kind: "agent", status: "done", sample_slug: Samples.slugs[2])

      get "/samples"

      expect(response).to have_http_status(:ok)
      links = page.css("main a[href^='/samples/']").map { |a| a["href"] }.uniq
      expect(links).to eq([ "/samples/#{Samples.slugs[0]}", "/samples/#{Samples.slugs[2]}" ])
      expect(page.at_css("main").text).to include("The Founder's Ledger", "Code & Coffee Weekly")
    end

    it "counts every sample's matches in one query" do
      other = create(:show, user: owner, title: "Code & Coffee Weekly")
      create_list(:sponsor_match, 2, report: create(:report, show: other, kind: "agent", status: "done", sample_slug: Samples.slugs[2]))
      queries = []
      counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('FROM "sponsor_matches"') }

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get "/samples" }

      expect(page.at_css("main").text.squish).to include("1 brand match", "2 brand matches")
      expect(queries.size).to eq(1)
    end

    it "says the samples are on their way when none is done" do
      report.update!(status: "failed")
      get "/samples"

      expect(response).to have_http_status(:ok)
      expect(page.css("main a[href^='/samples/']")).to be_empty
      expect(page.at_css("main").text).to include("Sample reports are on their way")
    end
  end
end

# The controller found "Food Beverage" under HelloFresh on the first sample: a category keeps its "and" (Fake catalog keys
# and names follow Qloo's, and the row spells "&" as "and").
RSpec.describe "Sample report categories" do
  it "reads Food and Beverage under a food brand on the generated #{Samples.slugs[0]}" do
    allow(Llm).to receive(:mode).and_return(:fake)
    Taste::Provider.reset!
    Podcasts::Directory.reset!
    # The first sample's slug on a show from the demo catalog: its real Podcast Index id is unknown there.
    Samples::Generate.call(io: StringIO.new, entries: [ Samples.entries.first.merge(directory_id: "fake-1") ])

    get "/samples/#{Samples.slugs[0]}"
    page = Nokogiri::HTML(response.body)
    categories = page.css(".match-row").to_h { |row| [ row.at_css(".match-name").text, row.at_css(".match-category")&.text ] }
    expect(categories.values).to include("Food and Beverage")
    expect(categories.values).not_to include("Food Beverage", "Health Wellness")
    expect(categories["HelloFresh"]).to eq("Food and Beverage") if categories.key?("HelloFresh")
  end
end
