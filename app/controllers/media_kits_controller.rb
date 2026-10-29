# The owner's side of a media kit: the private preview (always available, watermarked, noindex), the editor, and
# publishing, which needs a verified show. Scoped to the user's own shows. Viewing never creates a kit row.
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
      redirect_to edit_show_media_kit_path(@show), notice: "Kit saved.", status: :see_other
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
      redirect_to edit_show_media_kit_path(@show), notice: "Published. Your kit is live at #{public_kit_url(@show.slug)}.", status: :see_other
    else
      redirect_to edit_show_media_kit_path(@show), alert: MediaKit::VERIFY_TO_PUBLISH, status: :see_other
    end
  end

  def unpublish
    @kit.unpublish! if @kit.persisted?
    redirect_to edit_show_media_kit_path(@show), notice: "Unpublished. Your public page is offline; your preview still works.", status: :see_other
  end

  private

  def set_show_and_kit
    @show = current_user.shows.find_by!(public_id: params[:show_id])
    @kit = @show.media_kit || @show.build_media_kit
  end

  # Only the contact email reaches the show through this form.
  def kit_params
    params.expect(media_kit: [ :headline, :about, :cover, :host_photo, :remove_cover, :remove_host_photo,
                               { rate_card_overrides: MediaKit::RATE_SLOTS.keys, hidden_brand_ids: [],
                                 show_attributes: [ :contact_email ] } ])
  end
end
