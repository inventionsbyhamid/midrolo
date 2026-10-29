module Claims
  # bin/rails demo:setup: makes or refreshes the demo show from config/demo_show.yml, safe to run again. The podcast
  # (found by Podcast::Listing::DEMO_GUID, its feed at /demo/feed.xml on this app's own address) with its episodes; the
  # owner's workspace, verified via "admin"; a published listing open to sponsors; and the downloads figure as a
  # "provided by the show" reading marked demo. The owner is the account with owner_email, else the first admin.
  # Returns the podcast.
  class DemoSetup
    class NoOwner < StandardError; end

    def self.call(owner_email: nil, today: Date.current) = new(owner_email:, today:).call

    def initialize(owner_email:, today:)
      @owner_email = owner_email.to_s.strip.downcase.presence
      @today = today
      @config = Rails.application.config_for(:demo_show)
    end

    def call
      owner = find_owner
      podcast = nil
      Podcast.transaction do
        podcast = save_podcast!
        save_episodes!(podcast)
        show = take_ownership!(podcast, owner)
        save_listing!(show)
        save_downloads!(podcast)
      end
      podcast.refresh_listing!
      podcast
    end

    private

    def find_owner
      user = @owner_email ? User.find_by("lower(email) = ?", @owner_email) : User.where(admin: true).order(:id).first
      user || raise(NoOwner, @owner_email ? "No account has the email #{@owner_email}." : "No admin account yet. Sign in, set users.admin, then run this again.")
    end

    def save_podcast!
      podcast = Podcast.demo.first || Podcast.new(podcast_guid: Podcast::DEMO_GUID, source: "admin")
      dates = episodes.map { |episode| episode[:published_at] }
      podcast.assign_attributes(
        title: @config[:title], author: @config[:author], description: @config[:description],
        categories: @config[:categories], language: @config[:language], website: root_url, feed_url: feed_url,
        explicit: false, itunes_type: "episodic", status: "active", indexable: false, owner_email: nil,
        episode_count: episodes.size, cadence_days: 7, first_published_at: dates.min, last_published_at: dates.max,
        next_fetch_at: nil, fetch_failures: 0, last_error: nil
      )
      podcast.save!
      podcast
    end

    def save_episodes!(podcast)
      episodes.each do |attrs|
        episode = podcast.episodes.find_or_initialize_by(guid: attrs[:guid])
        episode.update!(attrs.slice(:title, :description, :published_at))
      end
    end

    # The owner's workspace becomes the owner show; another account's verified workspace (a different owner before)
    # goes back to a draft.
    def take_ownership!(podcast, owner)
      podcast.shows.where.not(verified_at: nil).where.not(user_id: owner.id).find_each { |show| show.update!(verified_at: nil) }
      show = owner.shows.find_or_create_by!(podcast: podcast)
      show.verify!(via: "admin")
      show
    end

    def save_listing!(show)
      listing = @config[:listing]
      kit = show.media_kit || show.build_media_kit
      kit.assign_attributes(
        headline: listing[:headline], about: listing[:about], open_to_sponsors: true,
        open_months: Podcast.listing_months(@today).first(listing[:open_months_ahead]),
        looking_for: listing[:looking_for], exclusions: listing[:exclusions], bands_only: false,
        published_at: kit.published_at || Time.current
      )
      kit.save!
    end

    # The same reading the owner's "provided by the show" form writes (lane L5), with evidence marking it demo.
    def save_downloads!(podcast)
      reading = podcast.stat_readings.find_or_initialize_by(metric: StatReading::DOWNLOADS_PER_EPISODE, source: "provided")
      value = @config[:downloads_per_episode].to_i
      reading.captured_at = Time.current if reading.new_record? || reading.value != value
      reading.update!(value: value, trust: "provided", period_days: nil, expires_at: nil, evidence: { "demo" => true })
    end

    def episodes
      @episodes ||= @config[:episodes].map do |episode|
        { guid: episode[:guid], title: episode[:title], description: episode[:description],
          published_at: (@today - episode[:days_ago].to_i).to_time(:utc) + 9.hours }
      end
    end

    def url_options = Rails.application.config.action_mailer.default_url_options || {}

    def feed_url = Rails.application.routes.url_helpers.demo_feed_url(**url_options)

    def root_url = Rails.application.routes.url_helpers.root_url(**url_options)
  end
end
