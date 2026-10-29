require "rails_helper"

RSpec.describe "Brand workspace" do
  include ActiveJob::TestHelper

  let(:user) { create(:user, email: "ada@fieldnote.example") }
  let(:brand) { create(:brand, name: "Fieldnote Coffee", domain: "fieldnote.example") }

  def last_code = ActionMailer::Base.deliveries.last.text_part.body.to_s[/\b\d{6}\b/]

  it "requires sign in for every page" do
    [ "/brand", "/brand/start", "/brand/searches/new", "/brand/searches", "/brand/saved", "/brand/verification/new" ].each do |path|
      get path
      expect(response).to redirect_to("/users/sign_in"), path
    end
  end

  context "when signed in without a brand" do
    before { sign_in user }

    it "sends the dashboard to onboarding" do
      get brand_root_path
      expect(response).to redirect_to(brand_start_path)
    end

    it "asks for the brand's name and website" do
      get brand_start_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Find podcasts your customers love", "Brand name", "Website")
    end

    it "makes the brand, the user its owner, and remembers the brand side for sign in" do
      post brand_profile_path, params: { name: "  Fieldnote   Coffee ", website: "https://www.Fieldnote.example/shop" }

      expect(response).to redirect_to(new_brand_search_path)
      made = Brand.find_by!(domain: "fieldnote.example")
      expect(made.name).to eq("Fieldnote Coffee")
      expect(user.brand_members.sole).to have_attributes(brand: made, role: "owner", verified_at: nil)
      expect(user.reload.last_role).to eq("brand")
    end

    it "joins a brand the catalog already knows by its website as a member, leaving its name as it is" do
      create(:brand_member, brand: brand)

      post brand_profile_path, params: { name: "Fieldnote", website: "fieldnote.example" }

      expect(user.brand_members.sole).to have_attributes(brand: brand, role: "member", verified_at: nil)
      expect(brand.reload.name).to eq("Fieldnote Coffee")
      expect(Brand.count).to eq(1)
    end

    it "refuses a free email domain as the website, a blank name and a missing website" do
      post brand_profile_path, params: { name: "Fieldnote", website: "gmail.com" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Use your company&#39;s website, not a free email provider.")

      post brand_profile_path, params: { name: " ", website: "fieldnote.example" }
      expect(response).to have_http_status(:unprocessable_content)

      [ "", "not a website" ].each do |website|
        post brand_profile_path, params: { name: "Fieldnote", website: website }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Enter your company&#39;s website")
      end
      expect(Brand.count).to eq(0)
    end

    # C1: typing a brand's name with your own website used to give that brand your domain, and a code at it made you a
    # verified member who could read the brand's requests, saved shows and searches.
    it "never gives a same-named brand the typed website, so a code at that website can't open its work" do
      acme = create(:brand, name: "Acme", domain: nil)
      colleague = create(:brand_member, brand: acme, verified_at: Time.current).user
      podcast = claimed_podcast(title: "Deep Work Daily")
      thread = start_request(podcast, BrandMember.find_by!(user: colleague))
      create(:saved_podcast, brand: acme, podcast: create(:podcast, title: "Acme Shortlist Show"), user: colleague)
      create(:fit_search, brand: acme, user: colleague, query: "Acme budget plans", status: "done")

      post brand_profile_path, params: { name: "Acme", website: "evil.example" }
      membership = user.brand_members.sole
      expect(membership.brand).not_to eq(acme)
      expect(membership.brand).to have_attributes(name: "Acme", domain: "evil.example")
      expect(acme.reload.domain).to be_nil

      perform_enqueued_jobs { post brand_verification_path, params: { email: "me@evil.example" } }
      patch brand_verification_path, params: { code: last_code }
      expect(membership.reload).to be_verified
      expect(acme.reload.verified_at).to be_nil

      get brand_inbox_path
      expect(response.body).not_to include("Deep Work Daily")
      get conversation_path(thread)
      expect(response).to have_http_status(:not_found)
      get brand_saved_podcasts_path
      expect(response.body).not_to include("Acme Shortlist Show")
      get brand_searches_path
      expect(response.body).not_to include("Acme budget plans")
    end

    it "shows a Save link that starts a brand, from the save button's frame" do
      podcast = create(:podcast)

      get brand_saved_podcast_path(podcast.public_id)

      expect(response.body).to include("turbo-frame", "save_podcast_#{podcast.public_id}", brand_start_path)
    end
  end

  context "when signed in as a brand member" do
    let!(:member) { create(:brand_member, user: user, brand: brand) }

    before { sign_in user }

    it "shows the dashboard with the unverified state and the next steps" do
      get brand_root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Fieldnote Coffee", "Unverified", "Verify your work email", "Run your first search")
      expect(user.reload.last_role).to eq("brand")
    end

    it "links each dashboard counter to its list and shows the latest requests with their status (review BR-15)" do
      podcast = claimed_podcast(owner: create(:user), title: "Shipping Soon")
      create(:conversation, brand: brand, started_by: user, podcast: podcast, status: "accepted")

      get brand_root_path

      page = Nokogiri::HTML(response.body)
      counters = page.css(".dash-counter").to_h { |link| [ link.at_css(".stat-label").text, link["href"] ] }
      expect(counters).to eq("Searches" => brand_searches_path, "Saved shows" => brand_saved_podcasts_path,
                             "Requests sent" => brand_inbox_path)
      requests = page.at_css("section[aria-labelledby='requests-heading']").text.squish
      expect(requests).to include("Shipping Soon", "Accepted")
      expect(page.at_css("section[aria-labelledby='saved-heading'] .empty-state").text).to include("Nothing saved yet")
    end

    it "lists saved shows with their fit, price and where the request stands (review BR-11)" do
      asked = claimed_podcast(owner: create(:user), title: "Shipping Soon")
      waiting = create(:podcast, :active, title: "Main Street Stories")
      [ asked, waiting ].each { |podcast| create(:saved_podcast, brand: brand, podcast: podcast, user: user) }
      search = create(:fit_search, user: user, brand: brand, status: "done")
      create(:fit_result, fit_search: search, podcast: waiting, position: 1, score: 59)
      create(:conversation, brand: brand, started_by: user, podcast: asked, status: "open")

      get brand_saved_podcasts_path

      rows = Nokogiri::HTML(response.body).css(".saved-row").to_h { |row| [ row.at_css(".result-title").text, row.text.squish ] }
      expect(rows["Main Street Stories"]).to include("Strong fit 59", "Hasn't joined Midrolo yet", "Not asked yet", "Ask anyway")
      expect(rows["Shipping Soon"]).to include("Open", "Asked", "Open your request")
    end

    it "shows a brand-only account its brand limits instead of the podcaster's plan (review BR-2)" do
      get account_path

      card = Nokogiri::HTML(response.body).css(".card").find { |c| c.at_css(".card-title")&.text == "Brand" }
      expect(card.text.squish).to include("Fit searches left today 5 of 5", "Requests left today 3 of 3", "Unverified",
                                          "Fieldnote Coffee", "Working on this one", "Verify your work email")
      expect(response.body).not_to include("Snapshot")
    end

    it "counts the brand side's unread conversations on the nav's Inbox, as the main nav does" do
      create(:conversation, brand: brand, started_by: user)
      create(:conversation, podcast: claimed_podcast(owner: user)) # the podcaster side: the brand inbox doesn't list it

      get brand_root_path

      header = Nokogiri::HTML(response.body).at_css("header.site-header")
      inbox = header.at_css("nav[aria-label='Main'] a[href='#{brand_inbox_path}']")
      expect(inbox.at_css(".nav-count").text).to eq("1")
      expect(inbox.at_css(".sr-only").text).to eq("1 unread")
      expect(header.at_css("button[aria-haspopup='dialog']").text.squish).to eq("Menu 1 1 unread")
    end

    describe "work email verification" do
      it "emails a code to the work address and verifies the member with it" do
        get new_brand_verification_path
        expect(response.body).to include('value="ada@fieldnote.example"')

        perform_enqueued_jobs { post brand_verification_path, params: { email: "ada@fieldnote.example" } }
        expect(response).to redirect_to(brand_verification_path)
        expect(ActionMailer::Base.deliveries.last.to).to eq([ "ada@fieldnote.example" ])

        follow_redirect!
        expect(response.body).to include("We sent a 6-digit code to a***@fieldnote.example")

        patch brand_verification_path, params: { code: "999999" == last_code ? "111111" : "999999" }
        expect(flash[:alert]).to eq("That code didn't match. You have 4 tries left.")

        patch brand_verification_path, params: { code: last_code }
        expect(response).to redirect_to(brand_root_path)
        expect(member.reload.verified_at).to be_present
        expect(brand.reload.verified_at).to be_present
      end

      it "refuses an address at another domain" do
        post brand_verification_path, params: { email: "ada@gmail.com" }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Free email addresses can&#39;t verify a brand")
        expect(member.reload.code_sent_to).to be_nil
      end

      it "sends a verified member back to the dashboard" do
        member.update!(verified_at: Time.current)

        get new_brand_verification_path
        expect(response).to redirect_to(brand_root_path)
      end
    end

    describe "fit searches" do
      it "offers the search form filled in from the brand" do
        get new_brand_search_path

        expect(response.body).to include('value="Fieldnote Coffee"', 'value="fieldnote.example"', "Food &amp; Beverage", "5 searches left today")
      end

      it "starts a search and shows its live agent steps" do
        expect do
          post brand_searches_path, params: { fit_search: { query: "Fieldnote Coffee", categories: [ "Food & Beverage" ], budget: "800" } }
        end.to have_enqueued_job(FitSearchJob)

        search = FitSearch.sole
        expect(response).to redirect_to(brand_search_path(search))
        expect(search).to have_attributes(user: user, brand: brand, categories: [ "Food & Beverage" ], budget_cents: 80_000)

        create(:agent_step, run: search, label: "Finding Fieldnote Coffee on Qloo…", status: "running")
        get brand_search_path(search)
        expect(response.body).to include("Our agent is searching Qloo", "Finding Fieldnote Coffee on Qloo…", "turbo-cable-stream-source",
                                         "agent_steps_fit_search_#{search.public_id}")
      end

      it "refuses past the member's searches a day" do
        create_list(:fit_search, 5, user: user, brand: brand)

        post brand_searches_path, params: { fit_search: { query: "Fieldnote Coffee" } }

        expect(response).to redirect_to(new_brand_search_path)
        expect(flash[:alert]).to include("Verify your work email to run more.")
        expect(FitSearch.count).to eq(5)
      end

      it "renders the ranked shows with why, proof, price, trust and the actions" do
        podcast = create(:podcast, :active, title: "The Founder's Ledger", open_to_sponsors: true, claimed_at: 1.day.ago,
                                            min_price_cents: 40_000, downloads_per_episode: 2400, downloads_trust: "verified")
        search = create(:fit_search, user: user, brand: brand, status: "done", summary: "One.\nTwo.\nThree.")
        create(:fit_result, fit_search: search, podcast: podcast, position: 1, score: 87, price_fit: "within",
                            reasons: [ "Qloo ranks it #2 of 50 podcasts for Fieldnote Coffee's customers." ],
                            proof: { "brands" => [ { "brand" => "Trade Coffee", "relation" => "competitor", "episodes" => 4 } ],
                                     "points" => { "taste" => 45, "proof" => 24, "price" => 15, "trust" => 10 } })

        create(:agent_step, run: search, tool: "find_brand", label: "Finding Fieldnote Coffee on Qloo…", status: "ok",
                            output_summary: "Found Fieldnote Coffee on Qloo in Food & Beverage.")

        get brand_search_path(search)

        body = response.body
        expect(body).to include("The Founder&#39;s Ledger", "87", "Strong fit", "Qloo ranks it #2 of 50 podcasts",
                                "Trade Coffee, a competitor, sponsored 4 episodes", "From $400 per episode",
                                "Within your budget", "2,400 plays per episode", "Request a spot", "/podcasts/#{podcast.slug}#request",
                                "Taste data from Qloo", "45 of 50", "Ready to book")
        expect(body).to include(brand_saved_podcasts_path) # the Save button
        expect(body.scan("<li>").size).to be >= 3 # the three summary bullets
        # How we found these (review BR-7): the agent's steps in a panel above the results.
        panel = Nokogiri::HTML(body).at_css("[data-how-found]")
        expect(panel.text.squish).to include("How we found these", "Found your brand on Qloo", "Found Fieldnote Coffee on Qloo in Food & Beverage.")
        expect(body.index("How we found these")).to be < body.index("The Founder&#39;s Ledger")
      end

      it "groups the results: bookable shows first, then shows that haven't joined, with one shared proof line" do
        search = create(:fit_search, user: user, brand: brand, status: "done", summary: "One.")
        ready = create(:podcast, :active, title: "Ready Show", open_to_sponsors: true, claimed_at: 1.day.ago, min_price_cents: 20_000)
        shared = { "brand" => "HelloFresh", "relation" => "category", "episodes" => 1 }
        unclaimed = Array.new(4) { |i| create(:podcast, :active, title: "Unclaimed #{i + 1}") }
        dormant = create(:podcast, title: "Quiet Show", status: "dormant", last_published_at: 14.months.ago)
        create(:fit_result, fit_search: search, podcast: ready, position: 1, score: 41, price_fit: "within",
                            proof: { "tier" => "ready", "brands" => [ shared ] })
        unclaimed.each_with_index do |podcast, i|
          create(:fit_result, fit_search: search, podcast: podcast, position: i + 2, score: 59 - i, price_fit: "ask",
                              proof: { "tier" => "unclaimed", "brands" => [ shared ] })
        end
        create(:fit_result, fit_search: search, podcast: dormant, position: 6, score: 70, price_fit: "ask", proof: {})

        get brand_search_path(search)

        page = Nokogiri::HTML(response.body)
        expect(page.css("[data-group]").map { |group| group["data-group"] }).to eq(%w[ready unclaimed dormant])
        expect(page.at_css("[data-group=ready] h3").text.squish).to eq("Ready to book 1")
        expect(page.css("[data-group=ready] .result-featured").size).to eq(1)
        expect(page.at_css("[data-group=ready]").text).to include("Request a spot")
        unclaimed_text = page.at_css("[data-group=unclaimed]").text
        expect(unclaimed_text).to include("Ask anyway")
        expect(unclaimed_text).not_to include("Request a spot", "No rate card yet")
        expect(page.at_css("[data-group=dormant]").text).to include("No new episode in")
        expect(page.at_css("[data-common-proof]").text.squish).to eq("HelloFresh, a brand in your category, sponsored 5 of these shows.")
        expect(page.css("[data-proof]")).to be_empty # said once above the list instead
      end

      it "asks for categories when Qloo didn't know the brand and none were picked (review BR-9)" do
        search = create(:fit_search, user: user, brand: brand, query: "Oatlyfe", website: "oatlyfe.com", status: "done",
                                     categories: [], qloo_brand_entity_id: nil)

        get brand_search_path(search)

        page = Nokogiri::HTML(response.body)
        expect(response.body).to include("No matches yet", "Qloo doesn't know Oatlyfe yet. Pick up to 3 categories")
        expect(response.body).not_to include("0 shows ranked")
        form = page.at_css(".no-matches form[action='#{brand_searches_path}']")
        expect(form.at_css("input[name='fit_search[query]']")["value"]).to eq("Oatlyfe")
        expect(form.css("input[type=checkbox][name='fit_search[categories][]']").size).to eq(FitSearch::Categories.names.size)
        expect(page.css("a.btn, button").map { |b| b.text.squish }.count("New search")).to eq(1)
      end

      it "fails a search stuck queued or running for 15 minutes, says so plainly and offers to run it again" do
        stuck = create(:fit_search, user: user, brand: brand, status: "running", started_at: 16.minutes.ago,
                                    query: "Fieldnote Coffee", website: "fieldnote.example", categories: [ "Food & Beverage" ],
                                    budget_cents: 80_000)
        lost = create(:fit_search, user: user, brand: brand, status: "queued", created_at: 20.minutes.ago)
        fresh = create(:fit_search, user: user, brand: brand, status: "running", started_at: 2.minutes.ago)

        get brand_searches_path
        expect([ stuck, lost, fresh ].map { |search| search.reload.status }).to eq(%w[failed failed running])
        expect(lost.error_message).to eq(FitSearch::STALE_MESSAGE)

        get brand_search_path(stuck)
        page = Nokogiri::HTML(response.body)
        expect(response.body).to include("This search didn&#39;t finish", "This search stopped before it finished. Run it again.")
        form = page.at_css("form[action='#{brand_searches_path}']")
        expect(form.at_css("button").text).to eq("Run it again")
        fields = form.css("input[type=hidden]").to_h { |input| [ input["name"], input["value"] ] }
        expect(fields).to include("fit_search[query]" => "Fieldnote Coffee", "fit_search[website]" => "fieldnote.example",
                                  "fit_search[categories][]" => "Food & Beverage", "fit_search[budget]" => "800")

        expect { post brand_searches_path, params: { fit_search: stuck.rerun_params } }.to have_enqueued_job(FitSearchJob)
        expect(FitSearch.order(:id).last).to have_attributes(query: "Fieldnote Coffee", categories: [ "Food & Beverage" ],
                                                             budget_cents: 80_000, status: "queued")
      end

      it "fails a stale search shown on the brand's dashboard too" do
        stuck = create(:fit_search, user: user, brand: brand, status: "queued", created_at: 1.hour.ago)
        get brand_root_path
        expect(stuck.reload).to have_attributes(status: "failed", error_message: FitSearch::STALE_MESSAGE)
      end

      it "404s for another user's search, and for an unverified teammate's" do
        stranger = create(:fit_search)
        teammate = create(:fit_search, brand: brand, user: create(:brand_member, brand: brand).user)

        [ stranger, teammate ].each do |search|
          get brand_search_path(search)
          expect(response).to have_http_status(:not_found)
          sign_in user
        end
      end

      it "lets a verified member open the brand's other searches" do
        member.update!(verified_at: Time.current)
        teammate = create(:fit_search, brand: brand, user: create(:brand_member, brand: brand).user)

        get brand_search_path(teammate)
        expect(response).to have_http_status(:ok)

        get brand_searches_path
        expect(response.body).to include(brand_search_path(teammate))
      end
    end

    describe "saved shows" do
      let(:podcast) { create(:podcast, title: "Deep Work Daily") }

      it "saves and unsaves a show, answering the button's frame with a Turbo Stream" do
        post brand_saved_podcasts_path, params: { podcast_id: podcast.public_id }, as: :turbo_stream

        expect(response.media_type).to eq(Mime[:turbo_stream])
        expect(response.body).to include("save_podcast_#{podcast.public_id}", "Saved")
        expect(brand.saved_podcasts.sole).to have_attributes(podcast: podcast, user: user)

        post brand_saved_podcasts_path, params: { podcast_id: podcast.public_id }, as: :turbo_stream
        expect(brand.saved_podcasts.count).to eq(1)

        get brand_saved_podcasts_path
        expect(response.body).to include("Deep Work Daily")

        delete brand_saved_podcast_path(podcast.public_id), as: :turbo_stream
        expect(brand.saved_podcasts.count).to eq(0)
      end

      it "redirects back without Turbo" do
        post brand_saved_podcasts_path, params: { podcast_id: podcast.public_id }

        expect(response).to redirect_to(brand_saved_podcasts_path)
        expect(flash[:notice]).to eq("Saved to your shortlist.")
      end

      it "answers the podcast page's lazy frame with the button in its state" do
        create(:saved_podcast, brand: brand, podcast: podcast, user: user)

        get brand_saved_podcast_path(podcast.public_id)

        expect(response.body).to include("save_podcast_#{podcast.public_id}", "Remove Deep Work Daily from your shortlist")
      end

      it "keeps teammates' saved shows from an unverified member" do
        create(:saved_podcast, brand: brand, podcast: podcast, user: create(:user))

        get brand_saved_podcasts_path
        expect(response.body).not_to include("Deep Work Daily")

        delete brand_saved_podcast_path(podcast.public_id), as: :turbo_stream
        expect(brand.saved_podcasts.count).to eq(1)

        member.update!(verified_at: Time.current)
        get brand_saved_podcasts_path
        expect(response.body).to include("Deep Work Daily")
      end

      # L7: the colleague's row came back and the button said Saved, but the member's list hides it and Remove did nothing.
      it "tells an unverified member a colleague already saved the show, instead of Saved" do
        create(:saved_podcast, brand: brand, podcast: podcast, user: create(:brand_member, brand: brand).user)

        post brand_saved_podcasts_path, params: { podcast_id: podcast.public_id }, as: :turbo_stream
        expect(response.body).to include("save_podcast_#{podcast.public_id}", "On your brand&#39;s list")
        expect(response.body).not_to include("Remove Deep Work Daily from your shortlist")

        post brand_saved_podcasts_path, params: { podcast_id: podcast.public_id }
        expect(flash[:notice]).to eq(Brands::SavedPodcastsController::COLLEAGUE_SAVED)
        expect(brand.saved_podcasts.count).to eq(1)

        member.update!(verified_at: Time.current)
        post brand_saved_podcasts_path, params: { podcast_id: podcast.public_id }, as: :turbo_stream
        expect(response.body).to include("Remove Deep Work Daily from your shortlist")
      end

      it "404s for a removed podcast" do
        podcast.update!(status: "removed")

        post brand_saved_podcasts_path, params: { podcast_id: podcast.public_id }
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "rate limits", :rate_limits do
    let!(:member) { create(:brand_member, user: user, brand: brand, verified_at: Time.current) }

    before { sign_in user }

    it "lets a member start 5 searches in 10 minutes" do
      5.times { post brand_searches_path, params: { fit_search: { query: "Fieldnote Coffee" } } }
      expect(FitSearch.count).to eq(5)

      post brand_searches_path, params: { fit_search: { query: "Fieldnote Coffee" } }
      expect(response).to have_http_status(:too_many_requests)
      expect(FitSearch.count).to eq(5)
    end

    it "sends at most 5 codes an hour per account" do
      member.update!(verified_at: nil)
      5.times do |i|
        travel(i * 61.seconds) { post brand_verification_path, params: { email: "ada#{i}@fieldnote.example" } }
      end

      travel(6.minutes) { post brand_verification_path, params: { email: "ada9@fieldnote.example" } }
      expect(response).to have_http_status(:too_many_requests)
    end
  end
end
