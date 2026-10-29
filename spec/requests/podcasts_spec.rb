require "rails_helper"

RSpec.describe "Podcast pages" do
  let(:browser) { "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15" }

  def doc = Nokogiri::HTML(response.body)
  def robots = doc.css("meta[name='robots']").map { |meta| meta["content"] }
  def json_ld = doc.css("script[type='application/ld+json']").map { |script| JSON.parse(script.text) }
  def visit(path, **headers) = get(path, headers: { "User-Agent" => browser }.merge(headers))

  def lazy_add_returns(found: [], added: [])
    allow(Catalog::LazyAdd).to receive(:call).and_return(Catalog::LazyAdd::Result.new(found: found, added: added))
  end

  describe "GET /podcasts" do
    let!(:active) { create(:podcast, :indexable, title: "Darknet Diaries", author: "Jack Rhysider", categories: [ "Technology" ], last_published_at: 2.days.ago) }

    before do
      create(:podcast, status: "dormant", title: "Old Radio", categories: [ "History" ], last_published_at: 1.year.ago)
      create(:podcast, status: "pending", title: "Pending Show")
      create(:podcast, status: "removed", title: "Removed Show")
    end

    it "lists the listed podcasts with their categories, and is indexable as a plain listing" do
      visit "/podcasts"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Find podcasts to sponsor", "Darknet Diaries", "Old Radio", "By Jack Rhysider")
      expect(response.body).not_to include("Pending Show", "Removed Show")
      expect(doc.css(".dir-categories a").map { |link| link["href"] }).to include("/podcasts/category/technology", "/podcasts/category/history")
      expect(robots).to be_empty
      expect(response.headers["X-Robots-Tag"]).to be_nil
    end

    it "noindexes a filtered listing and a later page" do
      visit "/podcasts?open=1"
      expect(robots).to eq([ "noindex, follow" ])
      expect(response.headers["X-Robots-Tag"]).to eq("noindex")

      visit "/podcasts?page=2"
      expect(robots).to eq([ "noindex, follow" ])
    end

    it "filters and says so when nothing matches" do
      visit "/podcasts?category=History"
      expect(response.body).to include("Old Radio")
      expect(response.body).not_to include("Darknet Diaries")

      visit "/podcasts?verified=1"
      expect(response.body).to include("No podcasts match these filters.")
    end

    it "searches the catalog, and shows a search hit the catalog just added as being added, with a poll" do
      added = create(:podcast, status: "pending", title: "Darknet Daily")
      lazy_add_returns(found: [ active ], added: [ added ])

      visit "/podcasts?q=darknet"

      expect(response).to have_http_status(:ok)
      expect(Catalog::LazyAdd).to have_received(:call).with("darknet", signed_in: false)
      expect(response.body).to include("Results for", "Darknet Diaries", "Found in the podcast directory", "Darknet Daily", "Adding this show")
      expect(response.body).not_to include("Old Radio")
      poll = doc.at_css("turbo-frame#adding_podcasts [data-controller='poll']")
      expect(poll["data-poll-url-value"]).to eq("/podcasts/search/adding?ids=#{added.public_id}&n=2")
      expect(robots).to eq([ "noindex, follow" ])
    end

    it "never asks the outside directory for a crawler, a later page or an empty search" do
      lazy_add_returns
      visit "/podcasts?q=darknet", "User-Agent" => "Googlebot/2.1 (+http://www.google.com/bot.html)"
      visit "/podcasts?q=darknet&page=2"
      visit "/podcasts?q="
      expect(Catalog::LazyAdd).not_to have_received(:call)
      expect(response).to have_http_status(:ok)
    end

    it "keeps working when the outside directory fails" do
      allow(Catalog::LazyAdd).to receive(:call).and_raise(Podcasts::Directory::Unavailable)
      visit "/podcasts?q=darknet"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Darknet Diaries")
    end

    it "says when a search finds nothing" do
      lazy_add_returns
      visit "/podcasts?q=zzzzqqq"
      expect(response.body).to include("No podcasts match")
    end

    it "tells a visitor who pasted a feed URL the catalog lacks to sign in to add it (code review M4)" do
      lazy_add_returns
      visit "/podcasts?q=#{CGI.escape('https://feeds.example.com/unknown.xml')}"
      expect(Catalog::LazyAdd).to have_received(:call).with("https://feeds.example.com/unknown.xml", signed_in: false)
      expect(response.body).to include("Sign in to add a show by its RSS feed")

      sign_in create(:user)
      visit "/podcasts?q=#{CGI.escape('https://feeds.example.com/unknown.xml')}"
      expect(Catalog::LazyAdd).to have_received(:call).with("https://feeds.example.com/unknown.xml", signed_in: true)
      expect(response.body).not_to include("Sign in to add a show by its RSS feed")
    end

    it "marks the search form as a search landmark" do
      visit "/podcasts"
      expect(doc.at_css("form.dir-search")["role"]).to eq("search")
    end

    # Code review M3, L2, L8: a card names the figure by its source, shows the owner's band when they chose ranges,
    # and shows nothing for a show nobody has claimed.
    it "shows a claimed show's plays or downloads per episode on its card, as a band when the owner chose ranges" do
      create(:podcast, :indexable, :claimed, title: "Verified Show", downloads_per_episode: 2_140, downloads_trust: "verified")
      create(:podcast, :indexable, :claimed, title: "Banded Show", downloads_per_episode: 4_200, downloads_trust: "provided",
                                             downloads_bands_only: true)
      create(:podcast, :indexable, title: "Unclaimed Show", downloads_per_episode: 9_999, downloads_trust: "verified")

      visit "/podcasts"

      cards = doc.css(".dir-card").to_h { |card| [ card.at_css(".dir-card-title").text.squish, card.at_css(".dir-card-facts").text.squish ] }
      expect(cards["Verified Show"]).to include("2,140 plays per episode")
      expect(cards["Banded Show"]).to include("2,500 to 5,000 downloads per episode")
      expect(cards["Banded Show"]).not_to include("4,200")
      expect(cards["Unclaimed Show"]).not_to include("per episode")
      expect(response.body).not_to include("9,999")
      expect(doc.css(".dir-card").find { |card| card.text.include?("Unclaimed Show") }.text).not_to include("Stats verified")
      # The chip is Podcast#stats_verified?, as on the page: a fresh verified reading, not the column alone.
      chip = -> { doc.css(".dir-card").find { |card| card.text.include?("Verified Show") }.text.include?("Stats verified") }
      expect(chip.call).to be(false)
      create(:stat_reading, podcast: Podcast.find_by!(title: "Verified Show"), source: "spotify", metric: "listeners_30d", trust: "verified")
      visit "/podcasts"
      expect(chip.call).to be(true)
      expect(doc.at_css("label[for='size']").text).to eq("Plays or downloads per episode")
      expect(doc.css("select#sort option").map(&:text)).to include("Most plays or downloads")

      visit "/podcasts?verified=1"
      expect(response.body).to include("Verified Show")
      expect(response.body).not_to include("Unclaimed Show")
    end

    it "throttles searches per visitor", :rate_limits do
      lazy_add_returns
      20.times { visit "/podcasts?q=darknet" }
      expect(response).to have_http_status(:ok)
      visit "/podcasts?q=darknet"
      expect(response).to have_http_status(:too_many_requests)
      visit "/podcasts"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /podcasts/search/adding" do
    it "shows each podcast's state and polls only while one is pending, and never past the cap" do
      pending_show = create(:podcast, status: "pending", title: "Still Reading")
      ready = create(:podcast, :active, title: "Ready Now")
      removed = create(:podcast, status: "removed", title: "Gone Show")
      ids = [ pending_show, ready, removed ].map(&:public_id).join(",")

      visit "/podcasts/search/adding?ids=#{ids}&n=3", "Turbo-Frame" => "adding_podcasts"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Still Reading", "Adding this show", "Ready Now")
      expect(response.body).not_to include("Gone Show")
      expect(doc.at_css("[data-controller='poll']")["data-poll-url-value"]).to include("n=4")
      expect(response.headers["X-Robots-Tag"]).to eq("noindex")

      visit "/podcasts/search/adding?ids=#{ids}&n=#{PodcastsController::MAX_POLLS}"
      expect(doc.at_css("[data-controller='poll']")).to be_nil
      expect(response.body).to include("Still reading.")

      pending_show.update!(status: "active")
      visit "/podcasts/search/adding?ids=#{ids}&n=5"
      expect(doc.at_css("[data-controller='poll']")).to be_nil
      expect(doc.css(".dir-card-link").map(&:text)).to eq([ "Still Reading", "Ready Now" ])
    end
  end

  describe "GET /podcasts/:slug" do
    let(:podcast) do
      create(:podcast, :indexable, title: "Darknet Diaries", author: "Jack Rhysider", categories: [ "Technology", "News" ],
                                   description: "True stories from the dark side of the internet.", language: "en-us",
                                   episode_count: 192, cadence_days: 14, first_published_at: Time.zone.local(2017, 9, 1),
                                   feed_checked_at: 3.hours.ago, feed_url: "https://feeds.example.com/darknet.xml",
                                   website: "https://darknetdiaries.com", apple_id: 1_296_350_485, explicit: true,
                                   itunes_type: "episodic", hosting_provider: "megaphone", measurement: [ "podtrac" ])
    end

    it "shows the page: header, numbers with their source, sections, details and the fine print" do
      episode = create(:episode, podcast: podcast, title: "Ricky", published_at: 3.days.ago, duration_seconds: 4_320, number: 181)
      create(:sponsor_mention, episode: episode, brand: create(:brand, name: "ThreatLocker"), published_at: 3.days.ago)
      create(:podcast_person, podcast: podcast, name: "Jack Rhysider", role: "host")

      visit "/podcasts/#{podcast.slug}"

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include("Darknet Diaries", "By Jack Rhysider", "Technology", "English", "New episode every 2 weeks",
                              "since Sep 2017", "192", "episodes in the feed", "sponsor in the last 90 days")
      expect(body).to include("Ricky", "Episode 181", "1 h 12 min", "ThreatLocker")
      expect(doc.text.squish).to include("Feed checked 3h ago.")
      expect(body).to include("Megaphone", "Podtrac", "Episodic", "Apple Podcasts")
      expect(body).to include("Remove this page", "isn't affiliated with Darknet Diaries")
      expect(doc.css(".pod-tab").map { |tab| tab.text.squish }).to eq([ "About", "Episodes 192", "Sponsors", "Audience", "Rates", "People 1" ])
      expect(doc.css("section[id]").map { |section| section["id"] }).to eq(%w[about episodes sponsors audience rates people])
      expect(doc.at_css("title").text).to eq("Darknet Diaries podcast sponsorship: rates, sponsors, audience | Midrolo")
      expect(doc.at_css("link[rel='canonical']")["href"]).to eq("http://www.example.com/podcasts/#{podcast.slug}")
      expect(robots).to be_empty
    end

    it "never hotlinks the feed's artwork or people's photos: stored pictures or initials only (code review L3)" do
      podcast.update!(artwork_image: nil, artwork_url: "https://tracker.example.com/art.jpg")
      create(:podcast_person, podcast: podcast, name: "Jack Rhysider", img_url: "https://tracker.example.com/jack.jpg")

      visit "/podcasts/#{podcast.slug}"

      expect(response.body).not_to include("tracker.example.com")
      expect(doc.css(".person .person-photo").map(&:text)).to eq([ "JR" ])
    end

    it "carries the PodcastSeries with sourced numbers and a breadcrumb, an Offer only with a published rate card" do
      visit "/podcasts/#{podcast.slug}"
      graph = json_ld.first["@graph"]
      series = graph.find { |node| node["@type"] == "PodcastSeries" }
      expect(series).to include("name" => "Darknet Diaries", "webFeed" => "https://feeds.example.com/darknet.xml",
                                "genre" => [ "Technology", "News" ], "inLanguage" => "en-us", "startDate" => "2017-09-01")
      expect(series["sameAs"]).to eq([ "https://darknetdiaries.com", "https://podcasts.apple.com/podcast/id1296350485" ])
      expect(series["additionalProperty"].first).to include("name" => "Episodes", "value" => 192)
      expect(series).not_to have_key("offers")
      expect(series).not_to have_key("aggregateRating")
      crumbs = graph.find { |node| node["@type"] == "BreadcrumbList" }["itemListElement"].map { |item| item["name"] }
      expect(crumbs).to eq([ "Podcasts", "Technology", "Darknet Diaries" ])

      podcast.update!(min_price_cents: 12_000, open_to_sponsors: true)
      visit "/podcasts/#{podcast.slug}"
      offer = json_ld.first["@graph"].first["offers"]
      expect(offer).to include("price" => 120.0, "priceCurrency" => "USD", "availability" => "https://schema.org/InStock")
    end

    it "shows a claimed show's listing: open to sponsors, the price, open months and who it's looking for" do
      show = create(:show, podcast: podcast)
      month = 1.month.from_now.strftime("%Y-%m")
      create(:media_kit, :published, show: show, open_to_sponsors: true, open_months: [ month ], looking_for: "Security tools for small teams.")
      podcast.update!(min_price_cents: 30_000, open_to_sponsors: true)

      visit "/podcasts/#{podcast.slug}"

      expect(response.body).to include("Open to sponsors", "Claimed by the show", "Sponsor this show", "$300",
                                       Date.strptime(month, "%Y-%m").strftime("%b %Y"), "Who we're looking for",
                                       "Security tools for small teams.")
      expect(response.body).not_to include("Host this show?")
    end

    it "says Stats verified once, in the header, for verified platform numbers with no per-episode figure" do
      create(:show, podcast: podcast, verified_at: 1.day.ago)
      podcast.update!(claimed_at: 1.day.ago)
      create(:stat_reading, podcast: podcast, metric: "streams_all_time", value: 18, source: "spotify", trust: "verified",
                            period_days: nil)

      visit "/podcasts/#{podcast.slug}"

      expect(podcast.reload.downloads_trust).not_to eq("verified")
      expect(doc.at_css(".pod-badges").text).to include("Stats verified")
      expect(doc.text.scan("Stats verified").size).to eq(1)
      expect(doc.at_css("#key-numbers")).to be_present
    end

    it "offers the claim box on an unclaimed show" do
      visit "/podcasts/#{podcast.slug}"
      expect(response.body).to include("Host this show?", "Claim this show", "No rate card yet.")
    end

    it "shows a visitor the audience teaser, never the Qloo panel, and a signed-in person the panel's place" do
      visit "/podcasts/#{podcast.slug}"
      expect(response.body).to include("See who listens.", "/podcasts/#{podcast.slug}/sign_in")

      sign_in create(:user)
      visit "/podcasts/#{podcast.slug}"
      expect(response.body).to include("No audience profile yet.")
      expect(response.body).not_to include("See who listens.")
    end

    it "lists similar shows for visitors from shared categories" do
      create(:podcast, :active, title: "Hacker News Daily", categories: [ "Technology" ])
      visit "/podcasts/#{podcast.slug}"
      expect(doc.css(".similar-title").map(&:text)).to eq([ "Hacker News Daily" ])
    end

    it "noindexes a podcast the catalog hasn't found worth indexing" do
      podcast.update!(indexable: false)
      visit "/podcasts/#{podcast.slug}"
      expect(response).to have_http_status(:ok)
      expect(robots).to eq([ "noindex, follow" ])
      expect(response.headers["X-Robots-Tag"]).to eq("noindex")
    end

    it "301s an earlier slug to the current one, and 404s an unknown one" do
      old = podcast.slug
      podcast.update!(title: "Darknet Diaries Renamed")

      visit "/podcasts/#{old}"
      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to("/podcasts/#{podcast.reload.slug}")

      visit "/podcasts/no-such-show"
      expect(response).to have_http_status(:not_found)
    end

    it "answers 410 for a removed podcast" do
      podcast.remove!
      visit "/podcasts/#{podcast.slug}"
      expect(response).to have_http_status(:gone)
      expect(response.body).to include("This page was removed.")
      expect(robots).to eq([ "noindex, nofollow" ])
    end

    it "shows a pending podcast as being read, with a poll, and noindex" do
      pending_show = create(:podcast, status: "pending", title: "Fresh From Search")
      visit "/podcasts/#{pending_show.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Fresh From Search", "Reading this show's feed.")
      expect(doc.at_css("turbo-frame#podcast_status [data-controller='poll']")["data-poll-url-value"])
        .to eq("/podcasts/#{pending_show.slug}/status?n=2")
      expect(robots).to eq([ "noindex, follow" ])
    end

    it "says when the feed couldn't be read" do
      podcast.update!(status: "failed", indexable: false)
      visit "/podcasts/#{podcast.slug}"
      expect(response.body).to include("We couldn't read this show's feed on our last try")
    end

    it "keeps a claimed show whose feed keeps failing, saying it couldn't be read recently" do
      podcast.update!(claimed_at: 1.day.ago, fetch_failures: 3, last_error: "feed_http_403")
      visit "/podcasts/#{podcast.slug}"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("We couldn't read this show's feed recently")
    end

    describe "caching" do
      it "answers a visitor's repeat request with 304 until the podcast, its listing or a request changes" do
        visit "/podcasts/#{podcast.slug}"
        etag = response.headers["ETag"]
        expect(etag).to be_present
        expect(response.headers["Cache-Control"]).to include("private")
        expect(response.headers["Cache-Control"]).not_to include("public")

        visit "/podcasts/#{podcast.slug}", "If-None-Match" => etag
        expect(response).to have_http_status(:not_modified)

        podcast.touch
        visit "/podcasts/#{podcast.slug}", "If-None-Match" => etag
        expect(response).to have_http_status(:ok)

        etag = response.headers["ETag"]
        create(:conversation, podcast: podcast, brand: create(:brand), status: "waiting_for_claim")
        visit "/podcasts/#{podcast.slug}", "If-None-Match" => etag
        expect(response).to have_http_status(:ok)
      end

      it "changes the visitor's ETag when the report the page's Audience reads finishes" do
        report = create(:report, show: create(:show, podcast: podcast, verified_at: 1.day.ago), status: "running")
        visit "/podcasts/#{podcast.slug}"
        etag = response.headers["ETag"]
        visit "/podcasts/#{podcast.slug}", "If-None-Match" => etag
        expect(response).to have_http_status(:not_modified)

        report.update!(status: "done", finished_at: Time.current)
        visit "/podcasts/#{podcast.slug}", "If-None-Match" => etag
        expect(response).to have_http_status(:ok)
      end

      it "never answers a signed-in person from the visitor's ETag, nor with a 304 of its own" do
        visit "/podcasts/#{podcast.slug}"
        anon = response.headers["ETag"]

        sign_in create(:user)
        visit "/podcasts/#{podcast.slug}", "If-None-Match" => anon
        expect(response).to have_http_status(:ok)
        expect(response.headers["ETag"]).not_to eq(anon)
      end
    end
  end

  describe "GET /podcasts/:slug/status" do
    it "polls while pending and reloads the page once ready" do
      podcast = create(:podcast, status: "pending")
      visit "/podcasts/#{podcast.slug}/status?n=2", "Turbo-Frame" => "podcast_status"
      expect(doc.at_css("[data-controller='poll']")["data-poll-url-value"]).to eq("/podcasts/#{podcast.slug}/status?n=3")

      podcast.update!(status: "active")
      visit "/podcasts/#{podcast.slug}/status?n=3", "Turbo-Frame" => "podcast_status"
      expect(doc.at_css("[data-controller='poll']")["data-poll-visit-value"]).to eq("true")
    end
  end

  describe "GET /podcasts/:slug/sign_in" do
    it "keeps the page to come back to and sends a visitor to sign in" do
      podcast = create(:podcast, :active)
      visit "/podcasts/#{podcast.slug}/sign_in"
      expect(response).to redirect_to(new_user_session_path)
      expect(session["user_return_to"]).to eq("/podcasts/#{podcast.slug}#audience")

      sign_in create(:user)
      visit "/podcasts/#{podcast.slug}/sign_in"
      expect(response).to redirect_to("/podcasts/#{podcast.slug}#audience")
    end
  end
end
