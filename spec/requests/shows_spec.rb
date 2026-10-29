require "rails_helper"

RSpec.describe "Shows" do
  let(:user) { create(:user) }

  def stub_directory(directory)
    allow(Podcasts::Directory).to receive(:current).and_return(directory)
  end

  context "when signed out" do
    it "redirects to sign in" do
      get "/shows"
      expect(response).to redirect_to("/users/sign_in")
      post "/shows", params: { directory_id: "fake-1" }
      expect(response).to redirect_to("/users/sign_in")
    end
  end

  context "when signed in" do
    before { sign_in user }

    describe "GET /shows" do
      it "sends a user with no shows to the add-a-show page" do
        get "/shows"
        expect(response).to redirect_to(new_show_path)
      end

      it "lists show cards with status and an add-another link" do
        show = create(:show, user: user, title: "My Great Show")
        create(:show, title: "Someone Else's")
        get "/shows"

        expect(response.body).to include("My Great Show", "No report yet", "Add another show", show_path(show))
        expect(response.body).not_to include("Someone Else")
      end

      it "ends each card on its next step: a first Snapshot, or the latest report (Task 20)" do
        fresh = create(:show, user: user, title: "Fresh Show")
        done = create(:show, user: user, title: "Done Show")
        report = create(:report, show: done, status: "done")
        get "/shows"
        cards = Nokogiri::HTML(response.body).css("main li.card")

        fresh_card = cards.find { |card| card.text.include?("Fresh Show") }
        expect(fresh_card.at_css("form[action='#{show_reports_path(fresh, kind: 'snapshot')}'] button.btn-primary").text)
          .to eq("Get my free Snapshot")
        done_card = cards.find { |card| card.text.include?("Done Show") }
        expect(done_card.at_css("a[href='#{show_report_path(done, report)}']").text.squish).to eq("Latest report: Report ready")
        expect(done_card.at_css("form")).to be_nil
      end

      it "says which shows are claimed, which are drafts and which another account manages (lane L4)" do
        claimed = create(:show, user: user, title: "Claimed Show")
        claimed.verify!(via: "admin")
        draft = create(:show, user: user, title: "Draft Show")
        elsewhere = create(:show, user: user, title: "Taken Show")
        create(:show, podcast: elsewhere.podcast).verify!(via: "admin")
        get "/shows"
        cards = Nokogiri::HTML(response.body).css("main li.card").index_by { |card| card.at_css(".type-h3").text }

        expect(cards["Claimed Show"].text.squish).to include("Claimed Your listing")
        expect(cards["Claimed Show"].at_css("a[href='#{edit_show_media_kit_path(claimed)}']")).to be_present
        expect(cards["Draft Show"].text.squish).to include("Draft Verify you own it")
        expect(cards["Draft Show"].at_css("a[href='#{new_show_verification_path(draft)}']")).to be_present
        expect(cards["Taken Show"].text.squish).to include("Managed by someone else Ask for access")
        expect(cards["Taken Show"].at_css("a[href='#{new_podcast_claim_path(elsewhere.podcast)}']")).to be_present
      end
    end

    describe "GET /shows/new" do
      it "renders the search box, results frame and paste form" do
        get "/shows/new"
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("search_results", "data-controller=\"autosubmit\"",
                                         "Paste your RSS or Apple Podcasts link instead")
        # A skeleton stands in for the results while a search loads (Task 20).
        expect(Nokogiri::HTML(response.body).at_css(".show-search .search-busy .skeleton[role='status']").text).to include("Searching")
        expect(Nokogiri::HTML(response.body).at_css(".show-search form[role='search']")).to be_present
      end

      it "shows the upgrade prompt when the plan's show limit is reached" do
        create(:show, user: user)
        get "/shows/new"
        expect(response.body).to include("Upgrade", "1 show")
        expect(response.body).not_to include("search_results")
        page = Nokogiri::HTML(response.body)
        expect(page.at_css("main .badge").text).to eq("Free")
        expect(page.at_xpath("//main//a[normalize-space()='Upgrade']")["href"]).to eq(pricing_path)
      end

      it "lets a Pro user add up to 3 shows, and a downgraded user keep every show they have" do
        create(:subscription, user: user, plan: "pro")
        create_list(:show, 2, user: user)
        get "/shows/new"
        expect(response.body).to include("search_results")

        create(:show, user: user)
        get "/shows/new"
        expect(response.body).to include("3 shows")
        expect(response.body).not_to include("search_results")

        user.subscriptions.update_all(status: "canceled", current_period_end: 1.day.ago)
        get "/shows"
        expect(Nokogiri::HTML(response.body).css("main li.card").size).to eq(3)
        get "/shows/new"
        expect(response.body).to include("1 show")
      end
    end

    describe "POST /shows" do
      it "creates a show from a directory id for the current user and goes to the details step" do
        expect { post "/shows", params: { directory_id: "fake-1" } }.to change(user.shows, :count).by(1)
                                                                    .and change(Podcast, :count).by(1)

        show = user.shows.last
        expect(show).to have_attributes(directory_id: "fake-1", title: "The Founder's Ledger", author: "Maya Brandt",
                                        feed_url: "fake://fake-1", categories: %w[Business Finance])
        expect(show.podcast).to have_attributes(source: "claim", apple_id: 1_000_000_001, status: "pending")
        expect(response).to redirect_to(edit_show_path(show, onboarding: 1))
        expect(Catalog::IngestPodcastJob).to have_been_enqueued.with(show.podcast.id).at_priority(0)
      end

      it "shows an inline error for an unknown directory id" do
        expect { post "/shows", params: { directory_id: "nope" } }.not_to change(Show, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("couldn&#39;t find that show")
      end

      it "treats a repeat of the same directory id as a duplicate" do
        existing = create(:show, user: user, directory_id: "fake-1", feed_url: "fake://fake-1")
        expect { post "/shows", params: { directory_id: "fake-1" } }.not_to change(Show, :count)
        expect(response).to redirect_to(show_path(existing))
        expect(flash[:notice]).to eq("You've already added this show.")
      end

      it "treats a repeat of the same pasted feed url as a duplicate" do
        existing = create(:show, user: user, feed_url: "https://example.com/rss.xml")
        post "/shows", params: { feed_url: "https://example.com/rss.xml" }
        expect(response).to redirect_to(show_path(existing))
        expect(flash[:notice]).to eq("You've already added this show.")
      end

      it "redirects to the existing show when a concurrent submit wins the race to the unique index" do
        user_id = user.id
        existing = nil
        # The duplicate pre-check genuinely misses; another request inserts the same show just before our save.
        allow_any_instance_of(Show).to receive(:save!) do |show|
          Show.insert_all!([ { user_id: user_id, podcast_id: show.podcast_id, public_id: SecureRandom.hex(8) } ])
          existing = Show.find_by!(user_id: user_id, podcast_id: show.podcast_id)
          raise ActiveRecord::RecordNotUnique
        end

        post "/shows", params: { directory_id: "fake-1" }

        expect(response).to redirect_to(show_path(existing))
        expect(flash[:notice]).to eq("You've already added this show.")
        expect(Show.where(user_id: user_id).count).to eq(1)
      end

      it "lets two users add the same show, as two workspaces for one podcast" do
        other = create(:show, user: create(:user), directory_id: "fake-1", feed_url: "fake://fake-1")
        expect { post "/shows", params: { directory_id: "fake-1" } }.to change(user.shows, :count).by(1)
                                                                    .and not_change(Podcast, :count)
        expect(user.shows.last.podcast).to eq(other.podcast)
      end

      it "finds the podcast by its feed URL however the URL is spelled" do
        podcast = create(:podcast, feed_url: "https://example.com/rss.xml")
        allow_any_instance_of(Podcasts::FeedReader).to receive(:read).and_return(
          Podcasts::Feed.new(title: "Feed", description: nil, owner_email: nil, owner_name: nil, episodes: [],
                             cadence_days: nil, warnings: [])
        )
        expect { post "/shows", params: { feed_url: "HTTPS://Example.COM/rss.xml/" } }.not_to change(Podcast, :count)
        expect(user.shows.last.podcast).to eq(podcast)
      end

      it "blocks a second show when the plan allows one, with an upgrade prompt" do
        create(:show, user: user)
        expect { post "/shows", params: { directory_id: "fake-2" } }.not_to change(Show, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Upgrade")
      end

      it "creates from a pasted feed url the directory knows" do
        post "/shows", params: { feed_url: "fake://fake-3" }
        expect(user.shows.last.directory_id).to eq("fake-3")
      end

      it "uses the itunes lookup for an Apple Podcasts link" do
        itunes_id = Podcasts::Directories::Fake.new.find("fake-4").itunes_id
        post "/shows", params: { feed_url: "https://podcasts.apple.com/us/podcast/side-hustle/id#{itunes_id}?i=1" }
        expect(user.shows.last.directory_id).to eq("fake-4")
      end

      it "errors on an Apple link the directory does not know" do
        post "/shows", params: { feed_url: "https://podcasts.apple.com/us/podcast/x/id999" }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Apple Podcasts")
      end

      it "builds a show from feed metadata when the directory does not know the feed" do
        feed = Podcasts::Feed.new(title: "Indie Feed", description: "About it", owner_email: "o@example.com",
                                  owner_name: "Olive", episodes: [], cadence_days: 7, warnings: [],
                                  website: "https://indie.example.com/")
        allow_any_instance_of(Podcasts::FeedReader).to receive(:read).and_return(feed)
        post "/shows", params: { feed_url: "https://indie.example.com/feed.xml" }

        expect(user.shows.last).to have_attributes(title: "Indie Feed", author: "Olive", description: "About it",
                                                   feed_url: "https://indie.example.com/feed.xml", directory_id: nil,
                                                   artwork_url: nil, owner_email: "o@example.com",
                                                   website: "https://indie.example.com/")
      end

      it "adds a scheme to a pasted url without one" do
        allow_any_instance_of(Podcasts::FeedReader).to receive(:read) do |_, url, **|
          Podcasts::Feed.new(title: url, description: nil, owner_email: nil, owner_name: nil, episodes: [], cadence_days: nil, warnings: [])
        end
        post "/shows", params: { feed_url: "indie.example.com/feed.xml" }
        expect(user.shows.last.feed_url).to eq("https://indie.example.com/feed.xml")
      end

      it "shows the feed error inline when the feed cannot be read" do
        %w[feed_blocked feed_unreadable].each do |warning|
          allow_any_instance_of(Podcasts::FeedReader).to receive(:read).and_return(Podcasts::Feed.unreadable(warning))
          expect { post "/shows", params: { feed_url: "https://bad.example.com/feed.xml" } }.not_to change(Show, :count)
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("We couldn&#39;t read that feed. Check the URL, or search for your show by name.")
        end
      end

      it "blocks internal urls through the feed reader" do
        post "/shows", params: { feed_url: "http://127.0.0.1/feed.xml" }
        expect(response).to have_http_status(:unprocessable_content)
        expect(Show.count).to eq(0)
      end

      it "explains when nothing was submitted" do
        post "/shows", params: { feed_url: "  " }
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "survives a directory outage" do
        directory = instance_double(Podcasts::Directories::Fake)
        allow(directory).to receive(:find).and_raise(Podcasts::Directory::Unavailable)
        stub_directory(directory)
        post "/shows", params: { directory_id: "fake-1" }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Search is unavailable right now")
      end
    end

    describe "GET /shows/:id" do
      it "renders the hub with header, details, report forms and media kit link" do
        show = create(:show, user: user, title: "Hub Show", author: "Hosty", categories: %w[Business Finance],
                             downloads_per_episode: 1200)
        get "/shows/#{show.public_id}"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Hub Show", "Hosty", "Business", "1,200", "Edit", edit_show_path(show),
                                         "Get my free Snapshot", "Run full report",
                                         "Media kit", edit_show_media_kit_path(show))
        expect(response.body).not_to include("Coming soon")
        # The next action comes before the details, so a phone shows it without scrolling (Task 20).
        titles = Nokogiri::HTML(response.body).css("main .card h2, main .card h3, main .card p.type-h3").map { |t| t.text.squish }
        expect(titles.index("Find sponsors")).to be < titles.index("Details")
      end

      it "is found by its public id, links to itself that way, and is a 404 by its database id (R147)" do
        show = create(:show, user: user, downloads_per_episode: 1200)
        get "/shows/#{show.public_id}"
        expect(response).to have_http_status(:ok)
        hrefs = Nokogiri::HTML(response.body).css("a[href^='/shows/']").map { |a| a["href"] }
        expect(hrefs).to include(edit_show_path(show))
        expect(edit_show_path(show)).to eq("/shows/#{show.public_id}/edit")

        expect(hrefs.grep(%r{\A/shows/#{show.id}(/|\z)})).to be_empty

        get "/shows/#{show.id}"
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 for another user's show" do
        other = create(:show)
        get "/shows/#{other.public_id}"
        expect(response).to have_http_status(:not_found)
      end

      context "when new runs are paused" do
        let(:show) { create(:show, user: user) }
        let(:actions) { Nokogiri::HTML(response.body).css(".card").find { |card| card.at_css("h2")&.text == "Find sponsors" } }

        before { AppSettings.pause_runs!("Back after maintenance") }

        it "says so, disables the run buttons and offers a notify-me checkbox" do
          get show_path(show)

          # A plain statement: only someone on the notify list is promised an email.
          expect(actions.at_css("[role='status']").text.squish).to eq("New reports are paused for now.")
          expect(actions.css("form[action^='#{show_reports_path(show)}']")).to be_empty
          expect(actions.css("button[disabled]").map { |button| button.text.squish })
            .to eq([ "Get my free Snapshot", "Run full report" ])
          form = actions.at_css("form[action='#{waitlist_entries_path}']")
          expect(form.at_css("input[name='price_key']")["value"]).to eq("notify")
          expect(form.at_css("input[type='checkbox'][required]")).to be_present
          expect(form.at_css("label").text.squish).to eq("Email me when new reports are back")
        end

        it "adds the user to the notify list once, then says they're on it" do
          2.times do
            post waitlist_entries_path, params: { price_key: "notify", notify: "1" }, headers: { "HTTP_REFERER" => show_url(show) }
            expect(response).to redirect_to(show_url(show))
            expect(flash[:notice]).to eq(WaitlistEntriesController::NOTIFY_CONFIRMATION)
          end
          expect(WaitlistEntry.sole).to have_attributes(email: user.email, price_key: "notify", user: user)

          get show_path(show)
          expect(actions.at_css("form[action='#{waitlist_entries_path}']")).to be_nil
          expect(actions.text.squish).to include("You're on the list. We'll email you when they're back.")
        end

        it "offers the notify box again on a later pause once the last one's email went out (R81)" do
          WaitlistEntry.join(email: user.email, price_key: "notify", user: user).update!(notified_at: 1.day.ago)

          get show_path(show)
          expect(actions.at_css("form[action='#{waitlist_entries_path}']")).to be_present
        end

        it "shows the run buttons again once runs resume" do
          AppSettings.resume_runs!
          get show_path(show)
          expect(actions.css("form[action^='#{show_reports_path(show)}']").size).to eq(2)
          expect(actions.text).not_to include("paused")
        end
      end
    end

    describe "editing" do
      let(:show) { create(:show, user: user) }

      it "renders the details form with the onboarding step" do
        get "/shows/#{show.public_id}/edit", params: { onboarding: 1 }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Your average downloads per episode in the first 30 days", "United Kingdom",
                                         "Skip for now")
        expect(response.body.scan("show[hints][comparable_shows][]").size).to eq(5)
        expect(response.body.scan("show[hints][topics][]").size).to eq(5)
      end

      it "updates details, normalizes hints and returns to the hub" do
        patch "/shows/#{show.public_id}", params: { show: { downloads_per_episode: "2500", country: "GB",
                                                       contact_email: "me@example.com",
                                                       hints: { comparable_shows: [ " Acquired ", "", "Planet Money" ],
                                                                topics: [ "saas", "" ] } } }
        expect(response).to redirect_to(show_path(show))
        expect(show.reload).to have_attributes(downloads_per_episode: 2500, country: "GB", contact_email: "me@example.com")
        expect(show.hints[:comparable_shows]).to eq([ "Acquired", "Planet Money" ])
        expect(show.hints[:topics]).to eq([ "saas" ])
      end

      describe "re-running a report that needed input" do
        include ActiveJob::TestHelper

        let(:hints) { { comparable_shows: [ "Acquired", "", "Planet Money" ], topics: [ "saas" ] } }

        it "saves the hints, starts the same kind of report and opens it" do
          create(:subscription, user: user)
          expect { patch "/shows/#{show.public_id}", params: { show: { hints: hints }, rerun: "agent" } }
            .to change(show.reports, :count).by(1).and have_enqueued_job(GenerateReportJob)
          report = show.reports.last
          expect(report).to have_attributes(kind: "agent", status: "queued")
          expect(response).to redirect_to(show_report_path(show, report))
          expect(show.reload.hints[:comparable_shows]).to eq([ "Acquired", "Planet Money" ])
        end

        it "keeps the hints and explains with an upgrade prompt when the plan doesn't allow the run" do
          refusal = Entitlements::NotAllowed.new(:limit, kind: :agent, bucket: :paid, used: 4, in_flight: 0, limit: 4,
                                                         period: "billing period")
          allow(Report).to receive(:start!).and_raise(refusal)
          patch "/shows/#{show.public_id}", params: { show: { hints: hints }, rerun: "agent" }
          expect(response).to redirect_to(show_path(show))
          expect(flash[:notice]).to eq("Details saved.")
          expect(flash[:upgrade]).to include("reason" => "limit", "kind" => "agent", "used" => 4, "limit" => 4)
          expect(show.reload.hints[:topics]).to eq([ "saas" ])
        end

        it "starts nothing when no comparable show was given and says what to add" do
          report = create(:report, show: show, kind: "agent", status: "needs_input")
          show.update!(hints: { comparable_shows: [ "Acquired" ], topics: [] })
          expect do
            patch "/shows/#{show.public_id}", params: { show: { hints: { comparable_shows: [ " ", "" ], topics: [ "saas" ] } },
                                                 rerun: "agent", report_id: report.public_id }
          end.not_to change(Report, :count)
          expect(response).to redirect_to(show_report_path(show, report))
          expect(flash[:alert]).to include("Add at least one show your listeners also like")
          expect(show.reload.hints[:comparable_shows]).to eq([ "Acquired" ])
        end

        it "falls back to the show page when the report to return to isn't this show's" do
          other = create(:report)
          patch "/shows/#{show.public_id}", params: { show: { hints: { comparable_shows: [ "" ] } }, rerun: "agent", report_id: other.id }
          expect(response).to redirect_to(show_path(show))
          expect(flash[:alert]).to include("Add at least one show")
        end

        it "ignores an unknown kind and just saves" do
          expect { patch "/shows/#{show.public_id}", params: { show: { hints: hints }, rerun: "bogus" } }.not_to change(Report, :count)
          expect(response).to redirect_to(show_path(show))
        end
      end

      it "re-renders with errors on invalid input" do
        patch "/shows/#{show.public_id}", params: { show: { downloads_per_episode: "-5", contact_email: "bad" } }
        expect(response).to have_http_status(:unprocessable_content)
        expect(show.reload.downloads_per_episode).to be_nil
      end

      it "does not allow changing identity fields" do
        patch "/shows/#{show.public_id}", params: { show: { title: "Hacked", user_id: create(:user).id, slug: "x" } }
        expect(show.reload.title).not_to eq("Hacked")
        expect(show.user).to eq(user)
      end

      it "returns 404 for another user's show" do
        other = create(:show)
        get "/shows/#{other.public_id}/edit"
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 when updating another user's show" do
        other = create(:show)
        patch "/shows/#{other.public_id}", params: { show: { country: "GB" } }
        expect(response).to have_http_status(:not_found)
        expect(other.reload.country).to eq("US")
      end
    end
  end
end

RSpec.describe "Show search" do
  before { sign_in create(:user) }

  it "requires sign-in" do
    sign_out :user
    get "/shows/search", params: { q: "finance" }
    expect(response).to redirect_to("/users/sign_in")
  end

  it "renders a result card per match with artwork, title, author, categories and the pick button" do
    get "/shows/search", params: { q: "founder" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="search_results"', "The Founder&#39;s Ledger", "Maya Brandt", "Business",
                                     "episodes", "This is my show", 'name="directory_id"', 'value="fake-1"')
    expect(response.body).to include("TF") # no artwork in the fake catalog: initials tile
  end

  # Code review L3: a directory's artwork URL is the feed's own, so it is never hotlinked; the initials tile stands in.
  it "shows initials for a directory hit with artwork, never hotlinking it" do
    info = Podcasts::ShowInfo.new(directory_id: "x", title: "Art Show", author: "A", description: "", artwork_url: "https://img.example.com/a.jpg",
                                  feed_url: "https://f.example.com", categories: [], episode_count: 1, itunes_id: nil, language: "en")
    allow(Podcasts::Directory.current).to receive(:search).and_return([ info ])
    get "/shows/search", params: { q: "art" }
    expect(response.body).to include("AS", "1 episode")
    expect(response.body).not_to include("img.example.com")
  end

  it "renders nothing for an empty query" do
    get "/shows/search", params: { q: "  " }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="search_results"')
    expect(response.body).not_to include("No shows found", "This is my show")
  end

  it "renders the empty state when nothing matches" do
    get "/shows/search", params: { q: "zzzzqqq" }
    expect(response.body).to include("No shows found. Try the exact title or paste your RSS feed URL.")
  end

  it "shows a friendly message, not a 500, when the directory is down" do
    allow(Podcasts::Directory.current).to receive(:search).and_raise(Podcasts::Directory::Unavailable)
    get "/shows/search", params: { q: "finance" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Search is unavailable right now. Try again in a minute, or paste your RSS feed URL.")
  end
end
