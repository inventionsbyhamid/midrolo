module Conversations
  # One message in a conversation, from the side the user is on (Conversation#side_for). The podcaster's first one is
  # their first reply (first_reply_at, which the podcast page's reply time reads).
  #
  # Email goes to the other side only when they had read everything before this message: one email per unread stretch,
  # however many messages follow, so a chatty thread can't spend the day's mail (MailBudget) or flood an inbox. Nothing
  # is emailed while a request waits for the claim: there is no podcaster yet, and the feed's owner is never written to.
  class Reply
    CLOSED = "This conversation is closed, so it can't take new messages.".freeze
    EMPTY = "Write a message first.".freeze
    TOO_LONG = "Keep it under #{Message::BODY_LIMIT.to_fs(:delimited)} characters.".freeze

    Result = Data.define(:message, :error) do
      def ok? = error.nil?
    end

    def self.call(...) = new(...).call

    def initialize(conversation:, user:, side:, body:)
      @conversation = conversation
      @user = user
      @side = side
      @body = body.to_s.strip
    end

    def call
      message = Message.new(conversation: @conversation, user: @user, body: @body)
      return Result.new(message: message, error: EMPTY) if @body.empty?
      return Result.new(message: message, error: TOO_LONG) unless message.valid?

      notify = false
      first_reply = false
      Conversation.transaction do
        @conversation.lock!
        next unless writable?

        other = (Conversation::SIDES - [ @side ]).first
        notify = !@conversation.waiting_for_claim? && !@conversation.unread_for?(other)
        message.save!
        if @side == :podcaster && @conversation.first_reply_at.nil?
          @conversation.record_reply!(at: message.created_at)
          first_reply = true
        end
        @conversation.mark_read!(@side)
      end
      return Result.new(message: message, error: CLOSED) unless message.persisted?

      @conversation.podcast.touch if first_reply # the page's reply time
      ConversationMailer.with(message: message).new_reply.deliver_later if notify
      Broadcast.changed(@conversation)
      Result.new(message: message, error: nil)
    end

    private

    # A waiting request only takes the brand's messages; a declined or closed one takes none.
    def writable? = @conversation.writable? && (@side == :brand || !@conversation.waiting_for_claim?)
  end
end
