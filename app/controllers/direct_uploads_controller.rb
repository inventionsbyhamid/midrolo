# Direct uploads for the media kit's photos (R149): the browser sends the file straight to storage and shows its
# progress, so a big photo never ties up a web worker. Active Storage's own endpoint stays closed (R134) because anyone
# could call it; this one signs an upload only for a signed-in user, only for a web image within the kit's size limit,
# and at most UPLOADS_PER_HOUR an hour. The signed URL fixes the size and checksum, so storage refuses any other file,
# and MediaKit checks the stored file again when the form attaches it. Unattached uploads are purged after a day
# (PurgeUnattachedBlobsJob).
class DirectUploadsController < ApplicationController
  include ActiveStorage::SetCurrent

  UPLOADS_PER_HOUR = 30

  before_action :authenticate_user!
  throttle to: UPLOADS_PER_HOUR, within: 1.hour, by: :user_or_ip, scope: "direct_uploads"

  def create
    args = blob_args
    problem = MediaKit.upload_problem(content_type: args[:content_type], byte_size: args[:byte_size])
    return render(json: { error: problem }, status: :unprocessable_content) if problem

    blob = ActiveStorage::Blob.create_before_direct_upload!(**args)
    render json: blob.as_json(root: false, methods: :signed_id)
                     .merge(direct_upload: { url: blob.service_url_for_direct_upload, headers: blob.service_headers_for_direct_upload })
  end

  private

  # No client metadata: keys like analyzed or identified would skip Active Storage's own checks.
  def blob_args
    args = params.expect(blob: %i[filename byte_size checksum content_type]).to_h.symbolize_keys
    args.merge(byte_size: Integer(args[:byte_size].to_s, exception: false))
  end
end
