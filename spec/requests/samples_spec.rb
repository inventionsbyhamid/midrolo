require "rails_helper"

# Public sample reports (spec §5.1, R78): the full agent report, read-only, for anyone.
RSpec.describe "Sample reports" do
  let(:owner) { User.find_or_create_by!(email: User::SAMPLES_EMAIL) }
  let(:show) { create(:show, user: owner, title: "The Founder's Ledger", author: "Maya Brandt") }
  let(:seeds) { { "entities" => [ { "id" => "q1", "name" => "Index Fund Mornings", "source" => "Similar on Qloo" } ], "tags" => [] } }
  let!(:report) do
    create(:report, show: show, kind: "agent", status: "done", sample_slug: "sample-one", spend_bucket: "sample",
                    profile_kind: "direct", seeds: seeds, summary: "People with this show's taste plan their money.")
  end

  before do
    create(:sponsor_match, report: report, name: "Fieldnote Coffee", position: 1)
    create(:agent_step, report: report, label: "Reading your last 15 episodes…", status: "ok")
  end

  def page = Nokogiri::HTML(response.body)

  describe "GET /samples/:slug" do
    it "shows the whole report to a visitor, labelled as a sample, with brand names" do
      get "/samples/sample-one"

      expect(response).to have_http_status(:ok)
      main = page.at_css("main").text.squish
      expect(main).to include("Sample — not affiliated with the show.", "The Founder's Ledger", "Fieldnote Coffee",
                              "Index Fund Mornings", "People with this show's taste plan their money.")
      expect(page.at_css("#report_matches")).to be_present
      expect(page.at_css("aside[aria-label='Agent steps']").text).to include("Reading your last 15 episodes…")
    end

    it "hides pitch, pipeline and every owner control, even from a signed-in user" do
      sign_in create(:user, :subscribed)
      get "/samples/sample-one"

      body = response.body
      expect(body).not_to include("Write my pitch", "Open pitch", "Pipeline", "Notes &amp; follow-up", "Re-run",
                                  "Try again", "Run full report")
      expect(page.css("main form")).to be_empty
      expect(page.at_css(".match-actions")).to be_nil
      expect(page.css("main a").map { |a| a["href"] }).not_to include(a_string_matching(%r{\A/(shows/\d+|sponsor_matches)}))
    end

    it "gives the sample its own title and share tags" do
      get "/samples/sample-one"

      expect(page.at_css("title").text).to eq("The Founder's Ledger sample sponsor report | Midrolo")
      expect(page.at_css("link[rel='canonical']")["href"]).to eq("http://www.example.com/samples/sample-one")
      expect(page.at_css("meta[property='og:image']")["content"]).to start_with("http://www.example.com/assets/og-")
    end

    it "is a 404, not a 500, for an unknown slug" do
      get "/samples/no-such-sample"
      expect(response).to have_http_status(:not_found)
    end

    it "is a 404 for a sample that isn't done yet" do
      report.update!(status: "running")
      get "/samples/sample-one"
      expect(response).to have_http_status(:not_found)
    end

    it "is a 404 for a slug samples.yml no longer lists" do
      report.update!(sample_slug: "retired-sample")
      get "/samples/retired-sample"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /samples" do
    it "lists the done samples, in samples.yml order" do
      other = create(:show, user: owner, title: "Code & Coffee Weekly")
      create(:report, show: other, kind: "agent", status: "done", sample_slug: "sample-three")

      get "/samples"

      expect(response).to have_http_status(:ok)
      links = page.css("main a[href^='/samples/']").map { |a| a["href"] }.uniq
      expect(links).to eq(%w[/samples/sample-one /samples/sample-three])
      expect(page.at_css("main").text).to include("The Founder's Ledger", "Code & Coffee Weekly")
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
