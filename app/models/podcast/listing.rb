# Podcast: claiming and the listing (rate card, open months, who it's looking for).
# Lane L4 adds its methods here, and only here (build spec section 10), so lanes don't edit the same model file.
#
# The listing lives on the owner show's media kit; the podcast keeps copies of what the directory filters on
# (refresh_listing!, in podcast.rb). The demo show (lib/tasks/demo.rake) is a podcast too: a fictional one Midrolo
# serves itself, which search engines, the directory and the sitemaps leave out.
module Podcast::Listing
  extend ActiveSupport::Concern

  # The demo show's podcast:guid: a fixed id, so demo:setup finds the same podcast on every run whatever host its
  # feed is served from.
  DEMO_GUID = "6d696472-6f6c-5000-8000-64656d6f7368".freeze
  # How many months ahead an owner can mark open, this month first.
  OPEN_MONTHS_AHEAD = 6
  # The ranges an owner who chose bands sees their downloads shown as (the directory's size filter uses the same).
  BANDS = [ [ 0...500, "Under 500" ], [ 500...1_000, "500 to 1,000" ], [ 1_000...2_500, "1,000 to 2,500" ],
            [ 2_500...5_000, "2,500 to 5,000" ], [ 5_000...10_000, "5,000 to 10,000" ],
            [ 10_000.., "10,000 and up" ] ].freeze

  included do
    scope :demo, -> { where(podcast_guid: DEMO_GUID) }
    # Everything but the demo show (podcast_guid is unique, so NULL guids stay in).
    scope :not_demo, -> { where("podcasts.podcast_guid IS DISTINCT FROM ?", DEMO_GUID) }

    # Whatever reads or rewrites the demo show, search engines never index it.
    before_save -> { self.indexable = false }, if: :demo?
  end

  class_methods do
    # "YYYY-MM" for this month and the next OPEN_MONTHS_AHEAD - 1, the months an owner can mark open.
    def listing_months(today = Date.current)
      Array.new(OPEN_MONTHS_AHEAD) { |offset| (today.beginning_of_month >> offset).strftime("%Y-%m") }
    end

    # The band a downloads figure falls in ("1,000 to 2,500"), or nil without one.
    def listing_band(value)
      return nil if value.nil?

      BANDS.find { |range, _| range.cover?(value.to_i) }&.last
    end
  end

  def demo? = podcast_guid == DEMO_GUID

  # The owner show's media kit when it's published: what the podcast page's Rates section shows. Reads the preloaded
  # owner show (Podcast.for_page) when there is one.
  def published_listing
    kit = owner_show&.media_kit
    kit if kit&.published?
  end

  # best_downloads_reading, picked from the preloaded readings when the page loaded them (Podcast.for_page), so the
  # podcast page's partials run no query for it. Same order: unexpired, most trusted, newest.
  def listing_downloads_reading(now = Time.current)
    return best_downloads_reading unless association(:stat_readings).loaded?

    trust_rank = StatReading::TRUST_LEVELS.each_with_index.to_h
    stat_readings.select { |reading| reading.metric == StatReading::DOWNLOADS_PER_EPISODE && !reading.expired?(now) }
                 .max_by { |reading| [ trust_rank.fetch(reading.trust, -1), reading.captured_at.to_f ] }
  end

  # Requests from brands that wait for this show to be claimed (the claim box counts them). One query.
  def waiting_requests_count
    Conversation.where(podcast_id: id, status: "waiting_for_claim").count
  end
end
