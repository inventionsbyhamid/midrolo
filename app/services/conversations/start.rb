module Conversations
  # A brand member's Request a spot (build spec L7): a conversation with its first message. On a claimed podcast it is
  # open and its owner gets an email; on an unclaimed one it waits for the claim (Conversations::ClaimHandoff), and the
  # feed's owner address is never written to.
  #
  # Spam guards, in order: not your own show, not a brand the show blocked, one ongoing request per show and brand
  # (asking again opens the one you have), and a daily allowance per brand member (User::Brands::DAILY_REQUESTS, lane
  # L6's: 3 unverified, 25 with a verified work email), counted over the last WINDOW. The membership row is locked while counting, so parallel requests can't pass the limit together, and the
  # podcast row too, so a claim (Show#verify! locks it) can't slip between "unclaimed" and the waiting row.
  class Start
    WINDOW = 24.hours
    OWN_SHOW = "This is your show. Requests to it arrive in your inbox.".freeze
    BLOCKED = "This show isn't taking requests from your brand.".freeze
    UNAVAILABLE = "This show isn't taking requests.".freeze

    # conversation is the new one, or the ongoing one asked for again (existing true); error is a sentence for the
    # person, nil on success. A form error leaves error as the form's first message.
    Result = Data.define(:conversation, :error, :existing) do
      def ok? = error.nil?
    end

    def self.call(...) = new(...).call

    def self.daily_limit(membership) = membership.user.brand_daily_request_limit(membership)

    def self.used_today(user) = Conversation.where(started_by_id: user.id, created_at: WINDOW.ago..).count

    def self.remaining_today(membership) = [ daily_limit(membership) - used_today(membership.user), 0 ].max

    # The refusal once the day's requests are used.
    def self.limit_message(membership)
      limit = daily_limit(membership)
      base = "You've sent #{limit} requests in the last 24 hours, the most for #{membership.verified? ? 'a verified' : 'an unverified'} brand."
      membership.verified? ? "#{base} Try again tomorrow." : "#{base} Verify your work email to send up to #{User::Brands::DAILY_REQUESTS[:verified]} a day."
    end

    # podcast: the show asked; membership: the asker's BrandMember (its user starts the conversation); form: a
    # RequestForm.
    def initialize(podcast:, membership:, form:)
      @podcast = podcast
      @membership = membership
      @user = membership.user
      @brand = membership.brand
      @form = form
    end

    def call
      return failure(@form.errors.full_messages.first) unless @form.valid?
      return failure(UNAVAILABLE) if @podcast.removed?
      return failure(OWN_SHOW) if owner?
      return failure(BLOCKED) if Block.exists?(podcast_id: @podcast.id, brand_id: @brand.id)

      existing = ongoing
      return Result.new(conversation: existing, error: nil, existing: true) if existing

      conversation = create
      return failure(self.class.limit_message(@membership)) unless conversation

      announce(conversation)
      Result.new(conversation: conversation, error: nil, existing: false)
    rescue ActiveRecord::RecordNotUnique
      # A parallel request for the same show and brand made it first.
      existing = ongoing
      existing ? Result.new(conversation: existing, error: nil, existing: true) : raise
    end

    private

    def failure(message) = Result.new(conversation: nil, error: message, existing: false)

    def owner? = Show.where(podcast_id: @podcast.id, user_id: @user.id).where.not(verified_at: nil).exists?

    def ongoing = Conversation.ongoing.find_by(podcast_id: @podcast.id, brand_id: @brand.id)

    # The new conversation, or nil when the day's requests are used.
    def create
      Conversation.transaction do
        @membership.lock!
        next nil if self.class.used_today(@user) >= self.class.daily_limit(@membership)

        @podcast.lock!
        claimed = Show.where(podcast_id: @podcast.id).where.not(verified_at: nil).exists?
        conversation = Conversation.create!(podcast: @podcast, brand: @brand, started_by: @user,
                                            status: claimed ? "open" : "waiting_for_claim",
                                            **@form.conversation_attributes)
        conversation.messages.create!(user: @user, body: @form.body)
        conversation.mark_read!(:brand)
        conversation
      end
    end

    # After the commit: the podcast page's caches change (its count and the asker's state), the owner of a claimed
    # show hears about it, and open inboxes refresh.
    def announce(conversation)
      @podcast.touch
      ConversationMailer.with(conversation: conversation).new_request.deliver_later if conversation.open?
      Broadcast.changed(conversation)
    end
  end
end
