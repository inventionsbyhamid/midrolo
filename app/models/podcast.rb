# The public record of one real podcast (build spec section 3): what its feed says, its stored artwork, where it
# stands in the catalog, and the listing and numbers denormalized from its owner's workspace. Each user's Show is
# their workspace for a podcast; at most one show per podcast is verified, the owner show.
#
# Each lane adds its methods in its own concern (spec section 10). Inside this class `Catalog`, `Sponsors` and `Stats`
# name those concerns, so the service and job namespaces are written `::Catalog::...`, `::Sponsors::...`, `::Stats::...`.
class Podcast < ApplicationRecord
  include HasPublicId
  include FriendlySlug
  include Catalog
  include Sponsors
  include Pages
  include Listing
  include Stats
  include Matching

  STATUSES = %w[pending active dormant failed removed].freeze
  SOURCES = %w[qloo_seed search claim sample admin].freeze
  DESCRIPTION_LIMIT = 4000
  # Solid Queue priorities, lower first (spec section 10): a claim or a search waits on the ingest (high), a refresh
  # doesn't (normal), and a seed fills in behind both (low).
  INGEST_PRIORITIES = { high: 0, normal: 10, low: 20 }.freeze
  # The columns a ShowLookup result fills (Podcasts::ShowInfo or a read feed).
  LOOKUP_COLUMNS = %i[title author description artwork_url categories episode_count language owner_email cadence_days
                      website].freeze

  belongs_to :artwork_image, class_name: "Image", optional: true
  has_many :shows, dependent: :restrict_with_exception
  # The verified show: the podcast's owner (at most one, a partial unique index on shows).
  has_one :owner_show, -> { where.not(verified_at: nil) }, class_name: "Show", inverse_of: false
  # The owner show's media kit, which holds the listing and the rate card.
  has_one :listing, through: :owner_show, source: :media_kit
  has_many :redirects, class_name: "PodcastRedirect", dependent: :delete_all
  # Mentions before episodes: they point at episodes.
  has_many :sponsor_mentions, dependent: :delete_all
  has_many :episodes, dependent: :delete_all
  has_many :people, class_name: "PodcastPerson", dependent: :delete_all
  has_many :stat_readings, dependent: :delete_all
  has_many :stat_connections, dependent: :destroy
  has_many :conversations, dependent: :destroy
  has_many :blocks, dependent: :delete_all
  has_many :fit_results, dependent: :delete_all
  has_many :saved_podcasts, dependent: :delete_all
  has_many :removal_requests, dependent: :delete_all

  encrypts :owner_email

  enum :status, STATUSES.index_with(&:itself), validate: true
  enum :source, SOURCES.index_with(&:itself), validate: true, prefix: true

  normalizes :feed_url, with: ->(url) { normalize_feed_url(url) }
  normalizes :description, with: ->(text) { text.strip.truncate(DESCRIPTION_LIMIT).presence }

  # After HasPublicId's, so the public id is there to take the slug's suffix from.
  before_validation :assign_slug, on: :create
  before_validation :assign_title_key, if: -> { title_key.nil? || will_save_change_to_title? }
  before_update :rename_slug, if: :will_save_change_to_title?
  after_update :keep_old_slug, if: :saved_change_to_slug?
  # A public kit's share image draws this artwork from storage, fetched off the request path.
  after_update_commit :request_share_artwork, if: :saved_change_to_artwork_url?

  validates :title, :slug, :feed_url, presence: true
  validates :feed_url, uniqueness: true
  validates :slug, uniqueness: true

  scope :indexable, -> { where(indexable: true) }
  scope :claimed, -> { where.not(claimed_at: nil) }
  scope :open_to_sponsors, -> { where(open_to_sponsors: true) }
  # Due for a feed check and not leased by another refresh (Catalog::RefreshDueJob), oldest due first.
  scope :due_for_fetch, lambda { |now = Time.current|
    where(next_fetch_at: ..now).where.not(status: "removed")
      .where("podcasts.leased_until IS NULL OR podcasts.leased_until < ?", now).order(:next_fetch_at)
  }

  # A feed URL as the catalog keys it: trimmed, scheme and host lowercased, no trailing slash. The migration that made
  # podcasts (MoveShowPodcastFieldsToPodcasts) does the same in SQL.
  def self.normalize_feed_url(url)
    url = url.to_s.strip
    url.sub(%r{\A[a-z][a-z0-9+.-]*://[^/?#]*}i, &:downcase).sub(%r{/+\z}, "").presence
  end

  # The key names from Qloo and the directory match on ("The Founder's Ledger" => "foundersledger").
  def self.title_key_for(title) = Research::Names.normalize(title)

  def self.slug_base(title) = friendly_slug_base(title, "podcast")

  # A readable slug no other podcast has, now or as an old slug: the title, then the title and host, then numbered.
  def self.free_podcast_slug(title, author, except: nil) = free_slug(title, fallback: "podcast", qualifiers: [ author ], except: except)

  # An old slug of another podcast still redirects there, so it can't be given out again.
  def self.reserved_slugs_like(base, like, except)
    redirects = PodcastRedirect.where(from_slug: base).or(PodcastRedirect.where("from_slug LIKE ?", like))
    redirects = redirects.where.not(podcast_id: except.id) if except&.persisted?
    redirects.pluck(:from_slug)
  end
  private_class_method :reserved_slugs_like

  # The first letters of a title's first two words, for an artwork tile ("The Founder's Ledger" => "TF").
  def self.initials_for(title)
    letters = title.to_s.split.map { |word| word[/\p{Alnum}/] }.compact.first(2).join.upcase
    letters.presence || "?"
  end

  # The podcast at slug, or at an earlier slug of it (podcast_redirects); nil for neither.
  def self.find_by_slug_or_redirect(slug)
    slug = slug.to_s
    return nil if slug.empty?

    find_by(slug: slug) || PodcastRedirect.includes(:podcast).find_by(from_slug: slug)&.podcast
  end

  # The podcast a directory id names (Podcasts::Directory#find's argument): a Podcast Index feed id, or the demo
  # directory's "fake-1"; nil when the catalog doesn't have it.
  def self.for_directory_id(directory_id)
    directory_id = directory_id.to_s.strip
    if (number = directory_number(directory_id))
      find_by(podcast_index_id: number)
    elsif directory_id.start_with?("fake-")
      find_by(feed_url: "#{Podcasts::Directories::Fake::FEED_PREFIX}#{directory_id}")
    end
  end

  # The podcast a ShowLookup result is about (ShowLookup::Result#attributes, plus source: for a new one): found by
  # Podcast Index id, Apple id or normalized feed URL, else built from the result. A found podcast only gains what it
  # lacks; the feed (Catalog::IngestPodcastJob) keeps the rest current.
  def self.find_or_build_from_lookup(attributes)
    attrs = attributes.to_h.symbolize_keys
    ids = { podcast_index_id: directory_number(attrs[:directory_id]), apple_id: directory_number(attrs[:itunes_id]) }
    feed_url = normalize_feed_url(attrs[:feed_url])
    podcast = (ids[:podcast_index_id] && find_by(podcast_index_id: ids[:podcast_index_id])) ||
              (ids[:apple_id] && find_by(apple_id: ids[:apple_id])) ||
              (feed_url && find_by(feed_url: feed_url)) ||
              new(feed_url: feed_url, source: attrs[:source].presence || "search")
    podcast.fill_from_lookup(attrs.merge(ids))
    podcast
  end

  # find_or_build_from_lookup, saved. A parallel request that saved the same podcast first wins, and its podcast is
  # returned.
  def self.find_or_create_from_lookup!(attributes)
    podcast = find_or_build_from_lookup(attributes)
    transaction(requires_new: true) { podcast.save! } if podcast.new_record? || podcast.changed?
    podcast
  rescue ActiveRecord::RecordNotUnique
    found = find_or_build_from_lookup(attributes)
    raise if found.new_record?

    found
  end

  # A directory's numeric id ("577105"), or nil for anything else (the demo directory's "fake-1").
  def self.directory_number(value)
    value = value.to_s.strip
    Integer(value, 10) if value.match?(/\A\d{1,18}\z/)
  end
  private_class_method :directory_number

  # Its URL is its slug (/podcasts/:slug); other records use their public id.
  def to_param = slug_in_database

  # Sets each lookup column the podcast lacks (all of them on a new one), and the directory ids no other podcast has.
  def fill_from_lookup(attrs)
    LOOKUP_COLUMNS.each do |column|
      value = attrs[column]
      value = Array(value).map(&:to_s).compact_blank if column == :categories
      value = value.to_i if column == :episode_count
      next if value.blank? || (persisted? && self[column].present? && self[column] != 0)

      self[column] = value
    end
    %i[podcast_index_id apple_id].each do |column|
      value = attrs[column]
      next if value.nil? || self[column].present? || self.class.where(column => value).exists?

      self[column] = value
    end
    self
  end

  # Catalog::IngestPodcastJob for this podcast, at a priority from INGEST_PRIORITIES.
  def ingest_later(priority: :normal)
    ::Catalog::IngestPodcastJob.set(priority: INGEST_PRIORITIES.fetch(priority)).perform_later(id)
  end

  # The stored artwork's variant (Image::VARIANTS: :thumb, :card, :page or :large), or nil before it is stored or once
  # it is suppressed. podcast_artwork_tag renders it.
  def artwork_variant(size)
    raise ArgumentError, "unknown artwork size #{size.inspect}" unless Image::VARIANTS.key?(size.to_s.to_sym)

    image = artwork_image
    image.file.variant(size.to_s.to_sym) if image&.visible? && image.file.attached?
  end

  def claimed? = claimed_at.present?

  # The freshest unexpired downloads-per-episode reading, the most trusted first (verified, provided, public, feed).
  def best_downloads_reading
    stat_readings.unexpired.where(metric: StatReading::DOWNLOADS_PER_EPISODE)
                 .in_order_of(:trust, StatReading::TRUST_LEVELS.reverse).order(captured_at: :desc).first
  end

  # The columns the directory filters on that come from the owner's workspace and the stats: whether it's open to
  # sponsors and its lowest rate (a published kit's), and its best downloads figure. L4 calls it when a listing is
  # saved, L5 after a sync or when readings expire, and Show when the owner show goes.
  def refresh_listing!
    kit = Show.where(podcast_id: id).where.not(verified_at: nil).first&.media_kit
    kit = nil unless kit&.published?
    rates = MediaKit::Content.new(kit).rates if kit
    reading = best_downloads_reading
    update!(open_to_sponsors: kit&.open_to_sponsors? || false,
            min_price_cents: rates && [ rates.midroll, rates.preroll, rates.postroll ].compact.min&.*(100),
            downloads_per_episode: reading&.value, downloads_trust: reading&.trust)
  end

  # Links the podcast to its Qloo entity once. An id another podcast already holds stays with it (unique index).
  def link_qloo_entity!(entity_id)
    entity_id = entity_id.to_s.strip
    return false if entity_id.empty? || qloo_entity_id.present? || self.class.exists?(qloo_entity_id: entity_id)

    self.class.transaction(requires_new: true) { update!(qloo_entity_id: entity_id) }
    true
  rescue ActiveRecord::RecordNotUnique
    restore_attributes([ :qloo_entity_id ])
    false
  end

  # The id Podcasts::Directory.current knows it by: the Podcast Index feed id, or the demo directory's id.
  def directory_id
    return podcast_index_id.to_s if podcast_index_id

    feed_url.delete_prefix(Podcasts::Directories::Fake::FEED_PREFIX) if feed_url&.start_with?(Podcasts::Directories::Fake::FEED_PREFIX)
  end

  def itunes_id = apple_id&.to_s

  def initials = self.class.initials_for(title)

  private

  def assign_slug
    self.slug ||= self.class.free_podcast_slug(title, author) if title.present?
  end

  def assign_title_key
    self.title_key = self.class.title_key_for(title)
  end

  def rename_slug
    self.slug = self.class.free_podcast_slug(title, author, except: self)
  end

  # The old slug keeps answering (a 301 to the new one); a slug the podcast takes back is no longer a redirect.
  def keep_old_slug
    PodcastRedirect.upsert({ from_slug: slug_before_last_save, podcast_id: id }, unique_by: :from_slug)
    redirects.where(from_slug: slug).delete_all
  end

  def request_share_artwork
    show = owner_show
    ShareImages::ArtworkStore.request(show) if show&.public_kit?
  end
end
