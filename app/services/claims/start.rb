module Claims
  # Starts (or continues) a user's claim on a podcast, from "Claim this show" on its public page:
  #
  #   1. the user's workspace for the podcast, reused or made. Never refused for the plan's show limit (build spec
  #      section 10: limits apply when a report starts).
  #   2. the feed, read fresh, for its owner address (stored on the podcast, so an email code can go out at once), and
  #      a feed read queued at high priority so the page catches up too.
  #   3. the instant claim: when that address is the user's own Google sign in, the show is theirs with no code.
  #
  # Returns a Result whose outcome is :verified (claimed just now), :owner (already theirs) or :verify (prove it with a
  # code or a feed token). Raises Show::AlreadyClaimed when another account owns the podcast.
  class Start
    Result = Data.define(:show, :outcome) do
      def verified? = outcome == :verified
    end

    def self.call(user:, podcast:, reader: Podcasts::FeedReader.new) = new(user:, podcast:, reader:).call

    def initialize(user:, podcast:, reader:)
      @user = user
      @podcast = podcast
      @reader = reader
    end

    def call
      existing = @user.shows.find_by(podcast_id: @podcast.id)
      return Result.new(show: existing, outcome: :owner) if existing&.verified?
      raise Show::AlreadyClaimed if @podcast.claimed?

      show = existing || create_workspace
      fresh_owner_email!
      @podcast.ingest_later(priority: :high)
      if show.owner_email_matches_user?(@podcast.owner_email)
        show.verify!(via: "email")
        show.sync_listing!
        return Result.new(show:, outcome: :verified)
      end
      Result.new(show:, outcome: :verify)
    end

    private

    # Another tab or a double click may make the same workspace first: then it's that one.
    def create_workspace
      @user.shows.create!(podcast: @podcast)
    rescue ActiveRecord::RecordNotUnique
      @user.shows.find_by!(podcast_id: @podcast.id)
    end

    # The owner address as the feed states it right now. A feed that can't be read keeps what the podcast had.
    def fresh_owner_email!
      return if @podcast.feed_url.blank?

      feed = @reader.read(@podcast.feed_url, max_episodes: 0, fresh: true)
      return if feed.warnings.any?

      address = feed.owner_email.presence
      @podcast.update!(owner_email: address) if address != @podcast.owner_email
    end
  end
end
