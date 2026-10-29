module Claims
  # "This show is managed by someone else": a signed-in user asks the owner of a claimed podcast for access (Spotify's
  # rule: one owner per show, later claimants ask the owner). One email to the owner's account address through
  # ClaimMailer (and so MailBudget), at most once per user and podcast in WINDOW. The owner's identity is never shown
  # to the person asking; their own name and email go to the owner so the owner can reply.
  #
  # Returns :sent, :already_sent (asked within WINDOW), :owner (it's the user's own show) or :unclaimed.
  class AccessRequest
    WINDOW = 7.days

    def self.call(user:, podcast:, store: Rails.cache) = new(user:, podcast:, store:).call

    # When user asked about podcast within WINDOW, or nil: the claim page then says so instead of offering the button
    # again (review PO-3). An ask stored before this kept `true`, which reads as "recently".
    def self.asked_at(user:, podcast:, store: Rails.cache)
      value = store.read(new(user:, podcast:, store:).send(:key))
      return if value.nil?

      Time.zone.parse(value.to_s) || true
    rescue ArgumentError
      true
    end

    def initialize(user:, podcast:, store:)
      @user = user
      @podcast = podcast
      @store = store
    end

    def call
      owner_show = @podcast.owner_show
      return :unclaimed unless owner_show
      return :owner if owner_show.user_id == @user.id
      return :already_sent unless @store.write(key, Time.current.iso8601, expires_in: WINDOW, unless_exist: true)

      ClaimMailer.with(podcast: @podcast, requester: @user).access_request.deliver_later
      :sent
    end

    private

    def key = "claims:access_request:#{@podcast.id}:#{@user.id}"
  end
end
