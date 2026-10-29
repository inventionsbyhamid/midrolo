require "rails_helper"

# Lane L4's podcast page partials, as lane L3's page renders them: with a podcast loaded the way Podcast.for_page loads
# it (strict loading, so a lazy load would raise).
module ListingPartials
  def page_podcast
    Podcast.includes(artwork_image: { file_attachment: :blob }, owner_show: %i[podcast media_kit user], listing: [],
                     stat_readings: []).strict_loading.find(podcast.id)
  end

  def render_partial(name)
    render(partial: "podcasts/#{name}", locals: { podcast: page_podcast })
    Nokogiri::HTML5.fragment(rendered)
  end
end

RSpec.describe "podcasts/_claim" do
  include ListingPartials

  let(:podcast) { create(:podcast, :active, title: "The Founder's Ledger", categories: [ "Business" ]) }

  describe "the claim box" do
    it "invites the host to claim, with the brands waiting, and keeps crawlers off the link" do
      create(:conversation, podcast: podcast, status: "waiting_for_claim")
      doc = render_partial("claim")

      expect(doc.text.squish).to include("Host this show?", "1 brand asked about sponsoring this show.")
      link = doc.at_css("a.btn")
      expect([ link.text, link["href"], link["rel"] ]).to eq([ "Claim this show", "/podcasts/#{podcast.slug}/claim", "nofollow" ])
    end

    it "is empty once the show is claimed, so the page shows nothing there" do
      create(:show, podcast: podcast).verify!(via: "admin")
      expect(render_partial("claim").text.strip).to be_empty
    end
  end
end

RSpec.describe "podcasts/_rates" do
  include ListingPartials

  let(:podcast) { create(:podcast, :active, title: "The Founder's Ledger", categories: [ "Business" ]) }

  describe "the rates" do
    let(:owner) { create(:show, podcast: podcast) }

    it "is empty without a published listing, so the page's empty state shows" do
      expect(render_partial("rates").text.strip).to be_empty

      owner.verify!(via: "admin")
      create(:media_kit, show: owner, open_to_sponsors: true)
      expect(render_partial("rates").text.strip).to be_empty
    end

    it "shows the rate card, open months, who they're looking for and exclusions, with the downloads source badged" do
      months = Podcast.listing_months
      create(:media_kit, :published, show: owner, open_to_sponsors: true, open_months: [ "2020-01", *months.first(2) ],
                                     looking_for: "Coffee and banks", exclusions: %w[Gambling Crypto],
                                     rate_card_overrides: { "midroll" => 150 })
      create(:stat_reading, podcast: podcast, value: 1800, source: "provided", trust: "provided",
                            captured_at: Time.zone.local(2026, 10, 29, 12))

      text = render_partial("rates").text.squish

      expect(text).to include("Open to sponsors", "Midroll $150", "Midroll set by the show; preroll and postroll suggested by Midrolo.",
                              "Suggested", "Coffee and banks",
                              "We don't advertise Gambling, Crypto",
                              "Based on 1,800 downloads per episode. Provided by the show Oct 29")
      expect(text).to include(*months.first(2).map { |month| Date.strptime(month, "%Y-%m").strftime("%b %Y") })
      expect(text).not_to include("Jan 2020") # a month gone by
      expect(rendered).to include("badge") # trust_badge
    end

    it "shows a band instead of the figure when the owner chose bands, and labels the demo show" do
      podcast.update!(podcast_guid: Podcast::DEMO_GUID)
      create(:media_kit, :published, show: owner, bands_only: true)
      create(:stat_reading, podcast: podcast, value: 1800, source: "provided", trust: "provided", evidence: { "demo" => true })

      text = render_partial("rates").text.squish

      expect(text).to include("Demo show", "Not taking sponsors right now", "Based on 1,000 to 2,500 downloads per episode.")
      expect(text).not_to include("1,800")
    end

    def basis_line(doc) = doc.css("p").map { |p| p.text.squish }.find { |text| text.start_with?("Based on") }

    # Code review L1, and the coordinator: the badge names its source in words, never the raw "provided" or
    # "platforms", and says it once.
    it "badges the basis in plain words: the show for provided numbers, the platforms for verified plays" do
      create(:media_kit, :published, show: owner)
      reading = create(:stat_reading, podcast: podcast, value: 1800, source: "provided", trust: "provided",
                                      evidence: { "demo" => true }, captured_at: Time.zone.local(2026, 10, 29, 12))

      badge = basis_line(render_partial("rates"))
      expect(badge).to eq("Based on 1,800 downloads per episode. Provided by the show Demo Oct 29")
      expect(badge.scan("provided").size + badge.scan("Provided").size).to eq(1)

      reading.update!(source: "platforms", trust: "verified", evidence: { "sources" => %w[spotify apple] })
      badge = basis_line(render_partial("rates"))
      expect(badge).to start_with("Based on 1,800 Spotify and Apple plays per episode. Verified with Spotify for Creators and")
      expect(badge).not_to include("platforms", "downloads")
    end
  end
end
