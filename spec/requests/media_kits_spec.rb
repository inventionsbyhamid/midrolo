require "rails_helper"

RSpec.describe "Media kits (owner)" do
  let(:user) { create(:user) }
  let(:show) { create(:show, user: user, title: "The Founder's Ledger", owner_email: "jane@example.com", downloads_per_episode: 3000) }

  it "requires sign in" do
    get show_media_kit_path(show)
    expect(response).to redirect_to("/users/sign_in")
  end

  context "when signed in" do
    before { sign_in user }

    it "404s for another user's show" do
      other = create(:show)
      other.verify!(via: "admin")
      [ -> { get show_media_kit_path(other) }, -> { get edit_show_media_kit_path(other) },
        -> { patch show_media_kit_path(other), params: { media_kit: { headline: "Mine now" } } },
        -> { patch publish_show_media_kit_path(other) }, -> { patch unpublish_show_media_kit_path(other) } ].each do |request|
        sign_in user # a 404 doesn't keep the test sign-in for the next request
        request.call
        expect(response).to have_http_status(:not_found)
      end
      expect(MediaKit.count).to eq(0)
    end

    describe "the private preview" do
      it "is always available, watermarked and noindex, without share tags" do
        get show_media_kit_path(show)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("kit-watermark", "Preview", '<meta name="robots" content="noindex, nofollow">')
        expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow")
        expect(response.body).not_to include("og:title")
        expect(MediaKit.count).to eq(0) # looking doesn't create anything
      end

      it "claims a verified owner only once the show is verified" do
        get show_media_kit_path(show)
        expect(response.body).not_to include("Verified owner")

        show.verify!(via: "admin")
        get show_media_kit_path(show)
        expect(response.body).to include("Verified owner of the RSS feed at example.com")
      end

      it "asks for a Snapshot when there is no audience data yet" do
        get show_media_kit_path(show)

        expect(response.body).to include("Run a Snapshot to add audience data")
        expect(response.body).to include(%(href="#{show_path(show)}"))
      end

      it "asks for a contact email, linking to the field, when brands would have no way to reach the show" do
        get show_media_kit_path(show)

        expect(response.body).to include("Add a contact email so brands can reach you")
        expect(response.body).to include(%(href="#{edit_show_media_kit_path(show, anchor: 'media_kit_show_attributes_contact_email')}"))
        expect(response.body).not_to include("Work with us")
      end

      it "drops the contact prompt once there is a contact email or a website" do
        show.podcast.update!(website: "https://foundersledger.example.com")
        get show_media_kit_path(show)
        expect(response.body).not_to include("Add a contact email so brands can reach you")
        expect(response.body).to include("Work with us", "Visit our website")

        show.update!(contact_email: "sponsors@example.com")
        get show_media_kit_path(show)
        expect(response.body).not_to include("Add a contact email so brands can reach you")
        expect(response.body).to include("mailto:sponsors@example.com")
      end

      it "shows audience data from the latest done report" do
        create(:report, show: show, status: "done", audience: { "tags" => [ { "id" => "t1", "name" => "Personal finance" } ] })
        get show_media_kit_path(show)

        expect(response.body).to include("Personal finance")
        expect(response.body).not_to include("Run a Snapshot to add audience data")
      end
    end

    describe "editing" do
      it "saves the story, rates, hidden brands and contact email" do
        patch show_media_kit_path(show), params: { media_kit: {
          headline: "Money lessons for founders", about: "We talk money.",
          rate_card_overrides: { midroll: "150", preroll: "", postroll: "40" },
          hidden_brand_ids: [ "", "b2" ], show_attributes: { contact_email: "sponsors@example.com" }
        } }

        expect(response).to redirect_to(edit_show_media_kit_path(show))
        expect(show.media_kit).to have_attributes(headline: "Money lessons for founders", about: "We talk money.",
                                                  rate_card_overrides: { "midroll" => 150, "postroll" => 40 },
                                                  hidden_brand_ids: [ "b2" ])
        expect(show.reload.contact_email).to eq("sponsors@example.com")
      end

      it "only lets the kit form change the show's contact email" do
        patch show_media_kit_path(show), params: { media_kit: { show_attributes: { contact_email: "a@example.com", title: "Hijacked",
                                                                                    owner_email: "evil@example.com", verified_at: Time.current } } }

        expect(show.reload).to have_attributes(contact_email: "a@example.com", title: "The Founder's Ledger",
                                               owner_email: "jane@example.com", verified_at: nil)
      end

      it "shows helpful errors for bad rates, a bad contact email and the wrong file type" do
        patch show_media_kit_path(show), params: { media_kit: {
          rate_card_overrides: { midroll: "-5" }, show_attributes: { contact_email: "not-an-email" },
          cover: Rack::Test::UploadedFile.new(StringIO.new('<svg xmlns="http://www.w3.org/2000/svg"></svg>'), "image/png", original_filename: "cover.png")
        } }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Midroll rate must be a whole number of dollars, 0 or more",
                                         "Cover must be a JPEG, PNG or WebP image", "Contact email is invalid")
        expect(show.reload.contact_email).to be_nil
      end

      it "uploads a host photo" do
        patch show_media_kit_path(show), params: { media_kit: {
          host_photo: Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/host.jpg"), "image/jpeg")
        } }

        expect(show.media_kit.host_photo).to be_attached
      end

      it "lists the audience's brands to hide, and the suggested rates as placeholders" do
        create(:report, show: show, status: "done", audience: { "brands" => [ { "id" => "b1", "name" => "Fieldnote Coffee" } ] })
        get edit_show_media_kit_path(show)

        expect(response.body).to include("Fieldnote Coffee", 'value="b1"', 'placeholder="115"')
      end
    end

    describe "the owner-address helper" do
      it "isn't offered before the show is verified" do
        get edit_show_media_kit_path(show)
        expect(response.body).not_to include("Use my feed's owner address")

        patch show_media_kit_path(show), params: { use_owner_email: "1", media_kit: { headline: "Hi" } }
        expect(show.reload.contact_email).to be_nil
      end

      it "copies the feed's owner address into the contact email in one click once verified" do
        show.verify!(via: "admin")
        get edit_show_media_kit_path(show)
        expect(response.body).to include("Use my feed's owner address (j***@example.com)")

        patch show_media_kit_path(show), params: { use_owner_email: "1", media_kit: { headline: "Hi" } }
        expect(show.reload.contact_email).to eq("jane@example.com")
      end
    end

    describe "publishing" do
      it "refuses an unverified show" do
        patch publish_show_media_kit_path(show)

        expect(response).to redirect_to(edit_show_media_kit_path(show))
        expect(flash[:alert]).to eq("Verify you own this show to publish.")
        expect(show.media_kit&.published_at).to be_nil
      end

      it "publishes a verified show's kit and unpublishes it again" do
        show.verify!(via: "admin")
        patch publish_show_media_kit_path(show)

        expect(response).to redirect_to(edit_show_media_kit_path(show))
        expect(flash[:notice]).to include("Published")
        expect(show.media_kit.reload).to be_published
        expect(show.podcast.reload.min_price_cents).to be_positive

        patch unpublish_show_media_kit_path(show)
        expect(show.media_kit.reload).not_to be_published
        expect(show.podcast.reload.min_price_cents).to be_nil
      end

      it "shows the publish and unpublish controls on the edit page" do
        get edit_show_media_kit_path(show)
        expect(response.body).to include("Verify you own this show to publish.", new_show_verification_path(show))

        show.verify!(via: "admin")
        get edit_show_media_kit_path(show)
        buttons = Nokogiri::HTML(response.body).css(".save-bar input[type=submit]").map { |input| [ input["name"], input["value"] ] }
        expect(buttons).to eq([ [ "publish", "Save and publish" ], [ "commit", "Save listing" ] ])

        patch publish_show_media_kit_path(show)
        get edit_show_media_kit_path(show)
        expect(response.body).to include(unpublish_show_media_kit_path(show), "/podcasts/#{show.slug}#rates")
        expect(Nokogiri::HTML(response.body).css(".save-bar input[type=submit]").map { |input| input["value"] }).to eq([ "Save listing" ])
      end

      it "saves and publishes in one step from the form (review PO-7)" do
        show.verify!(via: "admin")
        patch show_media_kit_path(show), params: { publish: "Save and publish", media_kit: { open_to_sponsors: "1" } }

        expect(response).to redirect_to(edit_show_media_kit_path(show))
        expect(flash[:notice]).to eq("Published. Your listing is live on your show's page.")
        expect(show.media_kit.reload).to have_attributes(open_to_sponsors: true, published?: true)
        expect(show.podcast.reload.open_to_sponsors).to be(true)
      end

      it "only saves an unverified show's listing when asked to publish" do
        patch show_media_kit_path(show), params: { publish: "Save and publish", media_kit: { open_to_sponsors: "1" } }

        expect(flash[:notice]).to eq("Saved.")
        expect(show.media_kit.reload).not_to be_published
      end

      it "sends a show another account manages to ask for access instead" do
        create(:show, podcast: show.podcast).verify!(via: "admin")
        get edit_show_media_kit_path(show)

        expect(response.body).to include("Another account manages this show", new_podcast_claim_path(show.podcast))
        expect(response.body).not_to include(new_show_verification_path(show))
      end
    end

    describe "the listing" do
      let(:months) { Podcast.listing_months }

      def save_listing(**fields)
        patch show_media_kit_path(show), params: { media_kit: { open_months: [ "" ] }.merge(fields) }
      end

      it "offers the next 6 months, open to sponsors, who you're looking for, exclusions and bands, as a draft before the claim" do
        get edit_show_media_kit_path(show)

        expect(response).to have_http_status(:ok)
        text = Nokogiri::HTML(response.body).text.squish
        expect(text).to include("Open to sponsors", "Months you're open", "Who you're looking for",
                                "What you won't advertise", "Show my numbers as a range", "Draft")
        months.each { |month| expect(response.body).to include(%(value="#{month}")) }
        expect(response.body).not_to include(%(value="#{(Date.current >> 6).strftime('%Y-%m')}"))
      end

      it "saves the listing, splitting exclusions on commas" do
        save_listing(open_to_sponsors: "1", open_months: [ "", months[1], months[0] ], looking_for: "Coffee and banks",
                     exclusions_text: "Gambling, alcohol ,, Gambling", bands_only: "1")

        expect(response).to redirect_to(edit_show_media_kit_path(show))
        expect(show.media_kit).to have_attributes(open_to_sponsors: true, open_months: months.first(2),
                                                  looking_for: "Coffee and banks", exclusions: %w[Gambling alcohol],
                                                  bands_only: true)
      end

      it "refuses a month that isn't one" do
        save_listing(open_months: [ "2026-13" ])

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Open months must be calendar months")
      end

      it "updates the podcast's directory columns when the owner's published listing is saved, and not for a draft" do
        save_listing(open_to_sponsors: "1", rate_card_overrides: { midroll: "150", preroll: "90", postroll: "60" })
        expect(show.podcast.reload).to have_attributes(open_to_sponsors: false, min_price_cents: nil)

        show.verify!(via: "admin")
        patch publish_show_media_kit_path(show)
        expect(show.podcast.reload).to have_attributes(open_to_sponsors: true, min_price_cents: 6_000)

        save_listing(open_to_sponsors: "0", rate_card_overrides: { midroll: "150", preroll: "90", postroll: "45" })
        expect(show.podcast.reload).to have_attributes(open_to_sponsors: false, min_price_cents: 4_500)
      end

      it "suggests rates from the podcast's best downloads reading and names its source" do
        create(:stat_reading, podcast: show.podcast, value: 12_000, source: "provided", trust: "provided",
                              captured_at: Time.zone.local(2026, 10, 29, 12))
        get edit_show_media_kit_path(show)

        expect(response.body).to include("It uses 12,000 downloads per episode, provided by the show (Oct 29).")
        expect(response.body).to include('placeholder="450"') # $25 CPM x 1.5 (business) on 12,000, not the typed 3,000
      end

      it "falls back to the downloads you entered, and asks for them when there are none" do
        get edit_show_media_kit_path(show)
        expect(response.body).to include("It uses 3,000 downloads per episode you entered.")

        show.update!(downloads_per_episode: nil)
        get edit_show_media_kit_path(show)
        expect(response.body).to include("We don't have your audience numbers yet.", show_stats_path(show))
      end
    end

    it "links the media kit from the show page and the report page" do
      report = create(:report, show: show, status: "done")
      get show_path(show)
      expect(response.body).to include(edit_show_media_kit_path(show))
      get show_report_path(show, report)
      expect(response.body).to include(show_media_kit_path(show))
    end
  end
end
