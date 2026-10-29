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

    it "joins a brand the catalog already knows by its website as a member" do
      create(:brand_member, brand: brand)

      post brand_profile_path, params: { name: "Fieldnote", website: "fieldnote.example" }

      expect(user.brand_members.sole).to have_attributes(brand: brand, role: "member")
      expect(Brand.count).to eq(1)
    end

    it "refuses a free email domain as the website, and a blank name" do
      post brand_profile_path, params: { name: "Fieldnote", website: "gmail.com" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Use your company&#39;s website, not a free email provider.")

      post brand_profile_path, params: { name: " ", website: "fieldnote.example" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(Brand.count).to eq(0)
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
        expect(response.body).to include("Our agent is working", "Finding Fieldnote Coffee on Qloo…", "turbo-cable-stream-source",
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

        get brand_search_path(search)

        body = response.body
        expect(body).to include("The Founder&#39;s Ledger", "87", "Qloo ranks it #2 of 50 podcasts",
                                "Trade Coffee, a competitor, sponsored 4 episodes", "From $400 per episode",
                                "Within your budget", "2,400 per episode", "Request a spot", "/podcasts/#{podcast.slug}#request",
                                "Taste data from Qloo", "45 of 50", "How the agent searched")
        expect(body).to include(brand_saved_podcasts_path) # the Save button
        expect(body.scan("<li>").size).to be >= 3 # the three summary bullets
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
