require "rails_helper"

# The dynamic share images (og:image) for sample reports and public media kits: 1200x630 PNGs drawn by
# ShareImages, public and cacheable, and a 404 for anything that isn't public.
RSpec.describe "Share images" do
  let(:artwork_url) { "https://cdn.example.com/art.jpg" }

  before { allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ]) }

  def dimensions = Vips::Image.new_from_buffer(response.body, "").then { |image| [ image.width, image.height ] }

  def expect_png
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/png")
    expect(response.body.b).to start_with("\x89PNG".b)
    expect(dimensions).to eq([ 1200, 630 ])
  end

  shared_examples "a cacheable share image" do
    it "is public for a day, with an ETag that answers a repeat with 304 and no cookie" do
      get path

      expect_png
      expect(response.headers["Cache-Control"]).to include("public", "max-age=86400")
      expect(response.headers["Set-Cookie"]).to be_blank
      etag = response.headers["ETag"]
      expect(etag).to be_present

      get path, headers: { "If-None-Match" => etag }
      expect(response).to have_http_status(:not_modified)
    end
  end

  describe "GET /samples/:slug/og.png" do
    let(:owner) { User.find_or_create_by!(email: User::SAMPLES_EMAIL) }
    let(:show) { create(:show, user: owner, title: "The Founder's Ledger") }
    let!(:report) do
      create(:report, show: show, kind: "agent", status: "done", sample_slug: "sample-one", spend_bucket: "sample",
                      audience: { "tags" => [ { "id" => "t1", "name" => "Personal finance" } ] })
    end
    let(:path) { "/samples/sample-one/og.png" }

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

    context "with a published kit" do
      before do
        create(:media_kit, :published, show: show)
        stub_request(:get, artwork_url).to_return(status: 200, body: file_fixture("host.jpg").binread,
                                                  headers: { "Content-Type" => "image/jpeg" })
      end

      it_behaves_like "a cacheable share image"

      it "fetches the show's artwork for the card" do
        get path

        expect_png
        expect(a_request(:get, artwork_url)).to have_been_made.once
      end

      it "still draws the card, with the mark in place of the artwork, when the artwork can't be fetched" do
        stub_request(:get, artwork_url).to_return(status: 500)
        get path

        expect_png
        expect(response.headers["Cache-Control"]).to include("public", "max-age=3600") # tried again within the hour
      end

      it "is a 404 once the kit is unpublished" do
        show.media_kit.unpublish!
        get path

        expect(response).to have_http_status(:not_found)
        expect(response.media_type).not_to eq("image/png")
        expect(a_request(:get, artwork_url)).not_to have_been_made
      end
    end

    it "is a 404 for an unknown slug, a kit never published and an unverified show" do
      get "/k/no-such-show/og.png"
      expect(response).to have_http_status(:not_found)

      create(:media_kit, show: show)
      show.verify!
      get path
      expect(response).to have_http_status(:not_found)

      show.media_kit.update!(published_at: Time.current)
      show.update!(verified_at: nil)
      get path
      expect(response).to have_http_status(:not_found)
    end
  end
end
