# Request a spot mail (build spec L7). Every message is low priority for MailBudget, so requests and replies stop at
# its low share of the day and verification codes keep the rest. Each method re-reads the state when the queued job
# renders it and sends nothing when it no longer applies.
#
# Never to a feed's owner address (Podcast#owner_email): the podcaster side is the account whose show is verified,
# so a show that hasn't claimed its page gets no mail at all. Brand text is never copied into an email (only its
# name, cut short), so a request can't carry a spam payload through Midrolo's sender.
#   new_request       a brand asked a claimed show for a spot (Conversations::Start)
#   new_reply         the other side wrote while you were caught up (Conversations::Reply)
#   answered          the show accepted or declined your request (ConversationsController)
#   waiting_requests  you claimed a show that brands had asked about (Conversations::ClaimHandoff)
#   reported          someone reported a conversation (for the admins)
class ConversationMailer < ApplicationMailer
  NAME_LIMIT = VerificationMailer::TITLE_LIMIT

  helper InboxHelper

  def new_request
    @conversation = params[:conversation]
    return unless @conversation.open?

    to = owner_email(@conversation.podcast)
    return unless to

    prepare(@conversation)
    low_priority
    mail to: to, subject: "#{@brand_name} asked about sponsoring #{@title}"
  end

  def new_reply
    @message = params[:message]
    @conversation = @message.conversation
    return if @conversation.waiting_for_claim? || !@conversation.writable?

    prepare(@conversation)
    @from_brand = @conversation.brand.members.exists?(user_id: @message.user_id)
    to = @from_brand ? owner_email(@conversation.podcast) : brand_email(@conversation)
    return unless to

    low_priority
    subject = @from_brand ? "#{@brand_name} wrote about #{@title}" : "#{@title} replied to your request"
    mail to: to, subject: subject
  end

  def answered
    @conversation = params[:conversation]
    return unless @conversation.accepted? || @conversation.declined?

    to = brand_email(@conversation)
    return unless to

    prepare(@conversation)
    low_priority
    mail to: to, subject: "#{@title} #{@conversation.accepted? ? 'accepted' : 'declined'} your request"
  end

  def waiting_requests
    @podcast = params[:podcast]
    @count = Conversation.open.where(podcast_id: @podcast.id, podcaster_read_at: nil).count
    to = owner_email(@podcast)
    return if @count.zero? || to.nil?

    @title = short(@podcast.title)
    @show = @podcast.owner_show
    low_priority
    mail to: to, subject: "#{@count == 1 ? 'A brand' : "#{@count} brands"} asked about sponsoring #{@title}"
  end

  def reported
    @conversation = params[:conversation]
    recipients = AdminMailer.recipients
    return if recipients.empty?

    prepare(@conversation)
    mail to: recipients, subject: "[#{APP_NAME}] Reported conversation: #{@brand_name} and #{@title}"
  end

  private

  def prepare(conversation)
    @title = short(conversation.podcast.title)
    @brand_name = short(conversation.brand.name)
  end

  def short(text) = text.to_s.squish.truncate(NAME_LIMIT)

  def low_priority
    headers[MailBudget::PRIORITY_HEADER] = "low"
  end

  # The account that owns the podcast (its verified show's user), never the feed's owner address.
  def owner_email(podcast) = podcast.owner_show&.user&.email.presence

  # Whoever asked. A request whose asker deleted their account has nobody to tell.
  def brand_email(conversation) = conversation.started_by&.email.presence
end
