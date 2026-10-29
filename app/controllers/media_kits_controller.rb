# The owner's side of a media kit: the private preview (always available, watermarked, noindex), the editor with the
# listing (open to sponsors, open months, who it's looking for, exclusions, bands; lane L4), and publishing, which
# needs a verified show and puts the listing on the podcast page. An unclaimed workspace edits a draft. Saving,
# publishing and unpublishing the owner show's kit update the podcast's directory columns (Show#sync_listing!).
# Scoped to the user's own shows. Viewing never creates a kit row.
class MediaKitsController < ApplicationController
  UPLOAD_MISSING = "That photo didn't finish uploading. Please choose it again.".freeze

  layout "app"
  before_action :authenticate_user!
  before_action :set_show_and_kit

  def show
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
    @content = MediaKit::Content.new(@kit)
    render layout: "kit"
  end

  def edit
    @content = MediaKit::Content.new(@kit)
  end

  # use_owner_email (the one-click helper) copies the feed's owner address into the contact email, but only on a
  # verified show: the owner proved that inbox or feed is theirs.
  def update
    @kit.assign_attributes(kit_params)
    @show.contact_email = @show.owner_email if params[:use_owner_email].present? && @show.verified? && @show.owner_email.present?
    if @kit.save
      @show.sync_listing!
      redirect_to edit_show_media_kit_path(@show), notice: "Saved.", status: :see_other
    else
      @content = MediaKit::Content.new(@kit)
      render :edit, status: :unprocessable_content
    end
  rescue ActiveStorage::FileNotFoundError
    # A direct upload's signed id whose file never reached storage (R149): Active Storage reads the file's start as
    # soon as it's assigned. The page's own uploads finish before the form is sent, so only a broken one lands here.
    redirect_to edit_show_media_kit_path(@show), alert: UPLOAD_MISSING, status: :see_other
  end

  def publish
    if @kit.publish!
      @show.sync_listing!
      redirect_to edit_show_media_kit_path(@show), notice: "Published. Your listing is live on your show's page.", status: :see_other
    else
      redirect_to edit_show_media_kit_path(@show), alert: MediaKit::VERIFY_TO_PUBLISH, status: :see_other
    end
  end

  def unpublish
    @kit.unpublish! if @kit.persisted?
    @show.sync_listing!
    redirect_to edit_show_media_kit_path(@show), notice: "Unpublished. Your rates are off your show's page; your preview still works.", status: :see_other
  end

  private

  def set_show_and_kit
    @show = current_user.shows.find_by!(public_id: params[:show_id])
    @kit = @show.media_kit || @show.build_media_kit
  end

  # Only the contact email reaches the show through this form. Exclusions arrive as one line, comma separated.
  def kit_params
    permitted = params.expect(media_kit: [ :headline, :about, :cover, :host_photo, :remove_cover, :remove_host_photo,
                                           :open_to_sponsors, :looking_for, :bands_only, :exclusions_text,
                                           { rate_card_overrides: MediaKit::RATE_SLOTS.keys, hidden_brand_ids: [],
                                             open_months: [], show_attributes: [ :contact_email ] } ])
    text = permitted.delete(:exclusions_text)
    permitted[:exclusions] = text.to_s.split(/[,\n]/) unless text.nil?
    permitted
  end
end
