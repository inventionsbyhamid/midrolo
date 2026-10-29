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
  # code or a feed token). Raises Show::AlreadyClaimed when another account owns the podcast, and Show::FeedMoved when
  # its feed moved while the owner address was being read (final review N1).
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
      read_from = fresh_owner_email!
      @podcast.ingest_later(priority: :high)
      if show.owner_email_matches_user?(@podcast.owner_email)
        show.verify!(via: "email", feed_url: read_from)
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

    # The owner address as the feed states it right now, stored only while the podcast still has the feed it came from,
    # so a move that lands during the read never gets the old feed's address (final review N1). A feed that can't be
    # read keeps what the podcast had. Returns the feed URL read: the instant claim holds only for that feed.
    def fresh_owner_email!
      url = @podcast.feed_url
      return nil if url.blank?

      feed = @reader.read(url, max_episodes: 0, fresh: true)
      address = feed.owner_email.presence
      @podcast.with_lock do
        same_feed = Podcast.same_feed_url?(url, @podcast.feed_url)
        @podcast.update!(owner_email: address) if feed.warnings.none? && same_feed && address != @podcast.owner_email
      end
      url
    end
  end
end
