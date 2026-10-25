require "rails_helper"

# R134: uploads go through the media kit form only, so Active Storage's open direct-upload endpoint is closed; the read
# routes the app's image URLs use (a blob or a variant by redirect, then the storage service) keep working.
RSpec.describe "Active Storage routes" do
  let(:kit) { create(:media_kit) }
  let(:helpers) { Rails.application.routes.url_helpers }

  before { kit.cover.attach(io: file_fixture("cover.png").open, filename: "cover.png") }

  it "answers 404 to a direct upload, creating no blob" do
    blob = { filename: "x.png", byte_size: 10, checksum: Digest::MD5.base64digest("0123456789"), content_type: "image/png" }

    expect { post "/rails/active_storage/direct_uploads", params: { blob: blob }, as: :json }
      .not_to change(ActiveStorage::Blob, :count)
    expect(response).to have_http_status(:not_found)
  end

  it "still serves a kit image's variant, the URL the media kit helper builds, through its redirect" do
    get helpers.rails_representation_path(kit.cover.variant(:hero), only_path: true)
    expect(response).to have_http_status(:found)

    get response.location
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/png")
  end

  it "still serves the original blob through its redirect" do
    get helpers.rails_blob_path(kit.cover, only_path: true)
    expect(response).to have_http_status(:found)

    get response.location
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(file_fixture("cover.png").binread)
  end
end
