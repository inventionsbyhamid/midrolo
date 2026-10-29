# Request a spot and the inboxes, for both sides (build spec L7). Every conversation is found through
# Conversation.visible_to(current_user), so a third party gets a 404; answers, blocks and closes check the side too.
#   index   /inbox (both sides), /shows/:show_id/inbox (one workspace), /brand/inbox (the brand side)
#   new     the Request a spot form on its own page (?podcast=<slug>), where sign in and brand setup come back to
#   create  the request (Conversations::Start: blocks, one ongoing request per show, the daily allowance)
#   show    a thread; opening it marks it read for the viewer's side
class ConversationsController < ApplicationController
  LIST_LIMIT = 100
  # Short: the thread's status note says the rest (review BR-14).
  SENT = "Request sent.".freeze
  WAITING = "Request saved.".freeze
  ALREADY_ASKED = "You already asked this show. Here's your conversation.".freeze
  NEEDS_BRAND = "Set up your brand first, then send your request.".freeze

  layout :inbox_layout

  # Public forms are throttled (build spec section 2). The daily allowance per brand member (3 unverified, 25 verified)
  # is Conversations::Start's, counted in the database.
  throttle to: 10, within: 1.minute, by: :user_or_ip, scope: "conversation_requests", only: :create
  throttle to: 30, within: 1.minute, by: :user_or_ip, scope: "conversation_changes",
           only: %i[accept decline close report block unblock]
  before_action :authenticate_user!
  before_action :set_conversation, except: %i[index new create]
  before_action :require_podcaster, only: %i[accept decline block unblock]

  # An answer or a close the conversation no longer allows (answered or closed in another tab).
  rescue_from Conversation::InvalidTransition do |error|
    redirect_to conversation_path(@conversation), alert: error.message
  end

  def index
    @show = current_user.shows.includes(:podcast).find_by!(public_id: params[:show_id]) if params[:show_id]
    @sides = index_sides
    @lists = @sides.index_with { |side| list_for(side) }
  end

  def new
    @podcast = find_podcast!
    @facts = page_facts
    viewer_redirect
    @form = Conversations::RequestForm.new unless performed?
  end

  def create
    @podcast = find_podcast!
    @facts = page_facts
    membership = chosen_membership
    return needs_brand unless membership

    @form = Conversations::RequestForm.new(request_params)
    result = Conversations::Start.call(podcast: @podcast, membership: membership, form: @form)
    if result.ok?
      redirect_to conversation_path(result.conversation), notice: sent_notice(result)
    else
      @error = result.error
      render :new, status: :unprocessable_content
    end
  end

  def show
    @conversation.mark_read!(@side) if @conversation.unread_for?(@side)
    @messages = @conversation.messages.includes(:user).to_a
    @brand_user_ids = BrandMember.where(brand_id: @conversation.brand_id).pluck(:user_id).to_set
    @blocked = @side == :podcaster && Conversations::BlockBrand.blocked?(podcast_id: @conversation.podcast_id,
                                                                         brand_id: @conversation.brand_id)
  end

  def accept
    @conversation.accept!
    ConversationMailer.with(conversation: @conversation).answered.deliver_later
    changed "You accepted this request. Agree the dates, the read and the price here."
  end

  def decline
    @conversation.decline!(reason: params[:decline_reason])
    ConversationMailer.with(conversation: @conversation).answered.deliver_later
    changed "Request declined. The brand sees your reason."
  rescue ActiveRecord::RecordInvalid
    redirect_to conversation_path(@conversation), alert: decline_problem
  end

  def close
    @conversation.close!(by: @side)
    changed(@side == :brand ? "Request withdrawn." : "Conversation closed.")
  end

  def report
    ConversationMailer.with(conversation: @conversation).reported.deliver_later if @conversation.report!
    redirect_to conversation_path(@conversation), notice: "Thanks for telling us. We'll look at this conversation."
  end

  def block
    Conversations::BlockBrand.block(podcast: @conversation.podcast, brand: @conversation.brand)
    redirect_to conversation_path(@conversation),
                notice: "You blocked #{@conversation.brand.name}. They can't send this show requests anymore."
  end

  def unblock
    Conversations::BlockBrand.unblock(podcast: @conversation.podcast, brand: @conversation.brand)
    redirect_to conversation_path(@conversation), notice: "You unblocked #{@conversation.brand.name}."
  end

  private

  def set_conversation
    @conversation = Conversation.visible_to(current_user).includes(:podcast, :brand, started_by: :brand_members)
                                .find_by!(public_id: params[:id])
    @side = @conversation.side_for(current_user) || raise(ActiveRecord::RecordNotFound)
  end

  # Only the podcast's owner answers, blocks and unblocks. The brand gets the same 404 as anyone else.
  def require_podcaster
    raise ActiveRecord::RecordNotFound unless @side == :podcaster
  end

  # After an answer or a close: the podcast page (its reply time and the brand's state) and open pages refresh.
  def changed(notice)
    @conversation.podcast.touch
    Conversations::Broadcast.changed(@conversation)
    redirect_to conversation_path(@conversation), notice: notice
  end

  def decline_problem
    reason = params[:decline_reason].to_s.squish
    return "Give a short reason so the brand knows why." if reason.empty?

    "Keep the reason under #{Conversation::DECLINE_REASON_LIMIT} characters."
  end

  # Which lists this inbox shows: one workspace's, the brand side, or every side the user is on.
  def index_sides
    return [ :podcaster ] if @show
    return [ :brand ] if params[:side] == "brand"

    sides = []
    sides << :podcaster if current_user.shows.where.not(verified_at: nil).exists?
    sides << :brand if current_user.brand_members.exists?
    sides
  end

  def list_for(side)
    scope = side == :podcaster ? Conversation.for_podcaster(current_user) : Conversation.for_brand_user(current_user)
    scope = scope.where(podcast_id: @show.podcast_id) if @show
    scope.includes(:brand, :messages, started_by: :brand_members, podcast: { artwork_image: { file_attachment: :blob } })
         .latest_first.limit(LIST_LIMIT).to_a
  end

  # The podcast asked about, by slug (or an earlier slug) or public id. Removed shows take no requests.
  def find_podcast!
    key = params[:podcast].to_s
    podcast = Podcast.find_by_slug_or_redirect(key) || Podcast.find_by(public_id: key)
    raise ActiveRecord::RecordNotFound if podcast.nil? || podcast.removed?

    podcast
  end

  # Where new sends a viewer who can't fill the form; nil for one who can (or who was blocked: the page says so).
  def viewer_redirect
    viewer = @facts.viewer
    case viewer.state
    when :no_brand then needs_brand
    when :ongoing then redirect_to(conversation_path(viewer.conversation), notice: ALREADY_ASKED)
    when :owner then redirect_to(inbox_path, notice: Conversations::Start::OWN_SHOW)
    end
  end

  # Brand setup (lane L6, at BRAND_HOME) comes back here through the stored location.
  def needs_brand
    store_location_for(:user, new_conversation_path(podcast: @podcast.to_param))
    redirect_to BRAND_HOME, notice: NEEDS_BRAND
  end

  # The brand the user asks as: the one the form names, else the one they work as in the brand workspace.
  def chosen_membership
    wanted = params.dig(:spot_request, :brand).to_s
    named = current_user.brand_members.joins(:brand).find_by(brands: { public_id: wanted }) if wanted.present?
    named || current_user.brand_member(session[:brand_member_id])
  end

  def page_facts = Conversations::PageFacts.new(@podcast, user: current_user, membership_id: session[:brand_member_id])

  # The brand side's pages (its inbox, a thread it reads, asking for a spot) sit in the brand workspace's frame; the
  # podcaster side's in the app's.
  def inbox_layout
    brand_side = { "index" => params[:side] == "brand", "new" => true, "create" => true }.fetch(action_name, @side == :brand)
    brand_side && current_user&.brand_member? ? "brand" : "app"
  end

  def request_params
    params.expect(spot_request: [ :format, :budget, :body, :brand, { months: [] } ])
  end

  def sent_notice(result)
    return ALREADY_ASKED if result.existing

    result.conversation.waiting_for_claim? ? WAITING : SENT
  end
end
