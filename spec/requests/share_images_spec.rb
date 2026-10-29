require "rails_helper"

# The dynamic share images (og:image) for sample reports and public media kits: 1200x630 PNGs drawn by
# ShareImages, public and cacheable, and a 404 for anything that isn't public. The request never touches the network
# (R98): a kit's artwork is fetched by FetchShareArtworkJob, and the card reads what that stored.
RSpec.describe "Share images" do
  let(:artwork_url) { "https://cdn.example.com/art.jpg" }
  let(:static_image) { Rails.root.join("app/assets/images/og.png").binread }

  def dimensions = Vips::Image.new_from_buffer(response.body, "").then { |image| [ image.width, image.height ] }

  # A drawn card: a 1200x630 PNG that isn't the landing page's static og.png.
  def expect_card
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/png")
    expect(response.body.b).to start_with("\x89PNG".b)
    expect(dimensions).to eq([ 1200, 630 ])
    expect(response.body.b).not_to eq(static_image.b)
  end

  def expect_static_image(max_age:)
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/png")
    expect(response.body.b).to eq(static_image.b)
    expect(response.headers["Cache-Control"]).to include("public", "max-age=#{max_age}")
  end

  # A MemoryStore for Rails.cache, unless the example group already set one up (with the kit's artwork in it).
  def with_memory_cache
    return if Rails.cache.is_a?(ActiveSupport::Cache::MemoryStore)

    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
  end

  shared_examples "a cacheable share image" do
    it "is public for a day, with an ETag that answers a repeat with 304 and no cookie" do
      get path

      expect_card
      expect(response.headers["Cache-Control"]).to include("public", "max-age=86400")
      expect(response.headers["Set-Cookie"]).to be_blank
      etag = response.headers["ETag"]
      expect(etag).to be_present

      get path, headers: { "If-None-Match" => etag }
      expect(response).to have_http_status(:not_modified)
    end

    it "is drawn once, complete, and then served from the cache" do
      with_memory_cache
      expect(ShareImages::Renderer).to receive(:png).once.and_call_original

      2.times { get path }
      expect_card
      expect(response.headers["Cache-Control"]).to include("max-age=86400")
    end

    it "draws once at a time: a request that finds another drawing gets the static image for a minute" do
      with_memory_cache
      get path
      key = card_key
      Rails.cache.delete(key)
      Rails.cache.write("#{key}/lock", 1)

      get path
      expect_static_image(max_age: 60)
      expect(Rails.cache.read(key)).to be_nil
    end

    it "serves the card another request drew while this one took the lock, instead of drawing it again" do
      with_memory_cache
      get path
      drawn = response.body
      key = card_key
      card = Rails.cache.read(key)
      allow(Rails.cache).to receive(:read).and_call_original
      allow(Rails.cache).to receive(:read).with(key).and_return(nil, card) # missing at first, there after the lock
      expect(ShareImages::Renderer).not_to receive(:png)

      get path
      expect(response.body).to eq(drawn)
    end

    it "serves the static image, briefly, when drawing fails" do
      allow(ShareImages::Renderer).to receive(:png).and_raise(Vips::Error, "svgload_buffer: bad")
      allow(Rails.error).to receive(:report)

      get path
      expect_static_image(max_age: 3600)
      expect(Rails.error).to have_received(:report).with(an_instance_of(Vips::Error), hash_including(handled: true))
    end
  end

  describe "GET /samples/:slug/og.png" do
    let(:owner) { User.find_or_create_by!(email: User::SAMPLES_EMAIL) }
    let(:show) { create(:show, user: owner, title: "The Founder's Ledger") }
    let!(:report) do
      create(:report, show: show, kind: "agent", status: "done", sample_slug: first_sample_slug, spend_bucket: "sample",
                      audience: { "tags" => [ { "id" => "t1", "name" => "Personal finance" } ] })
    end
    let(:path) { "/samples/#{first_sample_slug}/og.png" }

    def card_key = ShareImages::SampleCard.new(report.reload).cache_key

    before { create(:sponsor_match, report: report, name: "Fieldnote Coffee", position: 1) }

    it_behaves_like "a cacheable share image"

    it "changes its ETag when the report changes" do
      get path
      first = response.headers["ETag"]

      travel 1.minute
      report.update!(audience: { "tags" => [ { "id" => "t2", "name" => "Startups" } ] })
      get path
      expect(response.headers["ETag"]).not_to eq(first)
    end

    it "loads only the report and its show, not its steps or matches" do
      tables = []
      counter = ->(*, payload) { tables << payload[:sql][/FROM "(\w+)"/, 1] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get path }

      expect_card
      expect(tables).not_to include("agent_steps")
      expect(tables.count("sponsor_matches")).to eq(1) # one COUNT for "1 brand match"
    end

    it "is a 404 for an unknown sample, an unfinished one and one samples.yml no longer lists" do
      get "/samples/no-such-sample/og.png"
      expect(response).to have_http_status(:not_found)

      report.update!(status: "running")
      get path
      expect(response).to have_http_status(:not_found)

      report.update!(status: "done", sample_slug: "retired-sample")
      get "/samples/retired-sample/og.png"
      expect(response).to have_http_status(:not_found)
      expect(response.media_type).not_to eq("image/png")
    end
  end

  describe "GET /k/:slug/og.png" do
    let(:user) { create(:user) }
    let(:show) do
      create(:show, user: user, title: "The Founder's Ledger", downloads_per_episode: 4200, artwork_url: artwork_url)
    end
    let(:path) { "/k/#{show.slug}/og.png" }
    let(:teal) { Vips::Image.black(240, 240, bands: 3).new_from_image([ 0, 128, 128 ]).bandjoin(255).pngsave_buffer }

    def card_key = ShareImages::KitCard.new(show.media_kit.reload).cache_key

    context "with a published kit" do
      before { create(:media_kit, :published, show: show) }

      context "and its artwork stored" do
        before do
          with_memory_cache
          ShareImages::ArtworkStore.write(artwork_url, teal)
        end

        it_behaves_like "a cacheable share image"
      end

      it "never fetches anything while drawing: with no artwork stored it draws the mark and queues the fetch" do
        expect(ShareImages::Artwork).not_to receive(:fetch)
        expect(Podcasts::SafeUrl).not_to receive(:check!)
        expect(Resolv).not_to receive(:getaddresses)

        expect { get path }.to have_enqueued_job(FetchShareArtworkJob).with(show.id).on_queue("artwork")

        expect_card
        expect(response.headers["Cache-Control"]).to include("public", "max-age=3600") # drawn again within the hour
        expect(a_request(:any, /.*/)).not_to have_been_made
      end

      it "draws the stored artwork without fetching it, for a day" do
        with_memory_cache
        ShareImages::ArtworkStore.write(artwork_url, teal)

        expect { get path }.not_to have_enqueued_job(FetchShareArtworkJob)
        expect_card
        expect(response.headers["Cache-Control"]).to include("max-age=86400")
        expect(a_request(:any, /.*/)).not_to have_been_made
      end

      it "is a 404 once the kit is unpublished" do
        show.media_kit.unpublish!
        get path

        expect(response).to have_http_status(:not_found)
        expect(response.media_type).not_to eq("image/png")
      end
    end

    it "is a 404 for an unknown slug, a kit never published and an unverified show" do
      get "/k/no-such-show/og.png"
      expect(response).to have_http_status(:not_found)

      create(:media_kit, show: show)
      show.verify!(via: "admin")
      get path
      expect(response).to have_http_status(:not_found)

      show.media_kit.update!(published_at: Time.current)
      show.update!(verified_at: nil)
      get path
      expect(response).to have_http_status(:not_found)
    end
  end
end
