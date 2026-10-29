require "rails_helper"

# R149: the media kit's photos go straight to storage through /uploads, which signs an upload only for a signed-in user
# and a web image within the kit's limit, at most 30 an hour. Active Storage's own endpoint stays closed (R134).
RSpec.describe "Direct uploads" do
  let(:user) { create(:user) }
  let(:photo) { file_fixture("cover.png").binread }

  def blob_params(**overrides)
    { filename: "cover.png", byte_size: photo.bytesize, checksum: Digest::MD5.base64digest(photo), content_type: "image/png" }
      .merge(overrides)
  end

  it "needs a signed-in user" do
    expect { post "/uploads", params: { blob: blob_params }, as: :json }.not_to change(ActiveStorage::Blob, :count)
    expect(response).to have_http_status(:unauthorized)
  end

  context "when signed in" do
    before { sign_in user }

    it "signs an upload for a small web image and says where to send it" do
      expect { post "/uploads", params: { blob: blob_params }, as: :json }.to change(ActiveStorage::Blob, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["signed_id"]).to be_present
      expect(response.parsed_body.dig("direct_upload", "url")).to be_present
      expect(response.parsed_body.dig("direct_upload", "headers", "Content-Type")).to eq("image/png")
    end

    it "keeps none of the metadata the browser sends" do
      post "/uploads", params: { blob: blob_params(metadata: { identified: true, analyzed: true }) }, as: :json

      expect(response).to have_http_status(:ok)
      expect(ActiveStorage::Blob.last.metadata).not_to include("identified", "analyzed")
    end

    it "refuses other types and sizes, creating nothing" do
      [ { content_type: "image/svg+xml" }, { content_type: "text/html" }, { byte_size: 5.megabytes + 1 }, { byte_size: 0 },
        { byte_size: "lots" } ].each do |overrides|
        expect { post "/uploads", params: { blob: blob_params(**overrides) }, as: :json }
          .not_to change(ActiveStorage::Blob, :count)
        expect(response).to have_http_status(:unprocessable_content), "expected #{overrides} to be refused"
      end
    end

    it "gives the kit editor's photo fields this endpoint and a progress bar" do
      show = create(:show, user: user)
      get edit_show_media_kit_path(show)

      page = Nokogiri::HTML(response.body)
      %w[cover host_photo].each do |name|
        field = page.at_css("input[type=file][name='media_kit[#{name}]']")
        expect(field["data-direct-upload-url"]).to eq("http://www.example.com/uploads")
        expect(field.ancestors("[data-controller=upload]").first.at_css("progress[data-upload-target=bar]")).to be_present
      end
    end

    it "attaches an uploaded photo when the kit form sends its signed id" do
      show = create(:show, user: user)
      post "/uploads", params: { blob: blob_params }, as: :json
      signed_id = response.parsed_body["signed_id"]
      blob = ActiveStorage::Blob.find_signed!(signed_id)
      ActiveStorage::Blob.service.upload(blob.key, StringIO.new(photo), checksum: blob.checksum) # the browser's PUT

      patch show_media_kit_path(show), params: { media_kit: { cover: signed_id } }

      expect(response).to redirect_to(edit_show_media_kit_path(show))
      expect(show.reload.media_kit.cover.blob).to eq(blob)
    end

    it "says so when the form sends an upload whose file never arrived, attaching nothing" do
      show = create(:show, user: user)
      post "/uploads", params: { blob: blob_params }, as: :json

      patch show_media_kit_path(show), params: { media_kit: { cover: response.parsed_body["signed_id"] } }

      expect(response).to redirect_to(edit_show_media_kit_path(show))
      expect(flash[:alert]).to eq(MediaKitsController::UPLOAD_MISSING)
      expect(show.reload.media_kit).to be_nil
    end

    it "doesn't show a photo whose form failed to save as the kit's current one" do
      show = create(:show, user: user)
      post "/uploads", params: { blob: blob_params(byte_size: 10, checksum: Digest::MD5.base64digest("0123456789")) }, as: :json
      signed_id = response.parsed_body["signed_id"]
      ActiveStorage::Blob.service.upload(ActiveStorage::Blob.find_signed!(signed_id).key, StringIO.new("0123456789"))

      patch show_media_kit_path(show), params: { media_kit: { cover: signed_id } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Cover couldn&#39;t be read as an image")
      page = Nokogiri::HTML(response.body)
      expect(page.at_css("img[alt='Your current cover']")).to be_nil
      expect(page.at_css("input[name='media_kit[remove_cover]'][type=checkbox]")).to be_nil
    end
  end

  it "signs at most 30 uploads an hour per user", :rate_limits do
    travel_to Time.utc(2026, 10, 29, 10, 20, 30)
    sign_in user
    30.times do
      post "/uploads", params: { blob: blob_params }, as: :json
      expect(response).to have_http_status(:ok)
    end

    expect { post "/uploads", params: { blob: blob_params }, as: :json }.not_to change(ActiveStorage::Blob, :count)
    expect(response).to have_http_status(:too_many_requests)
  end
end
