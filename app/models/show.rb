# A user's workspace for a podcast (build spec section 3): their downloads figure, country, contact email, hints for
# the research, reports, matches, media kit and verification. What the show is (title, feed, artwork...) lives on its
# Podcast, the public record every user's workspace for the same show shares; Show reads it from there and never
# writes it. At most one show per podcast is verified: the podcast's owner show.
class Show < ApplicationRecord
  include HasPublicId
  include Claiming

  # Raised by verify! when another account's show already owns the podcast.
  class AlreadyClaimed < StandardError
    MESSAGE = "Another account has already claimed this show. If it's yours, write to us and we'll sort it out.".freeze

    def initialize(message = MESSAGE) = super
  end

  COUNTRIES = { "US" => "United States", "GB" => "United Kingdom", "CA" => "Canada", "AU" => "Australia", "IN" => "India" }.freeze
  HINT_KEYS = %w[comparable_shows topics].freeze
  HINT_LIMIT = 5
  HINT_LENGTH = 100
  # How an owner proved control (verify!): an emailed code or a feed token (ShowVerification's kinds), a hosting
  # account that lists the feed, or an admin.
  VERIFIED_VIA = %w[email feed_token host_api admin].freeze
  # The podcast's columns a show reads as its own.
  PODCAST_ATTRIBUTES = %i[title author description artwork_url categories episode_count language cadence_days owner_email
                          slug qloo_entity_id website feed_url directory_id itunes_id initials].freeze

  belongs_to :user
  belongs_to :podcast
  has_many :reports, dependent: :destroy
  # Preloadable (includes(:latest_report)) so lists don't N+1.
  has_one :latest_report, -> { order(created_at: :desc, id: :desc) }, class_name: "Report", inverse_of: :show
  has_many :sponsor_matches, dependent: :destroy
  has_one :media_kit, dependent: :destroy
  has_many :verifications, class_name: "ShowVerification", dependent: :destroy
  has_many :stat_connections, dependent: :destroy

  delegate(*PODCAST_ATTRIBUTES, to: :podcast)

  before_validation :normalize_hints
  # The owner show going (its user deleted the account) unclaims the podcast and takes its listing down.
  after_destroy :release_claim, if: :verified?

  validates :country, inclusion: { in: COUNTRIES.keys }
  validates :downloads_per_episode, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :podcast_id, uniqueness: { scope: :user_id }, allow_nil: true

  # An http(s) URL with a host, or nil, so feed text never reaches an href unchecked.
  def self.http_url(value)
    uri = URI.parse(value.to_s.strip)
    uri.to_s if uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end

  # Hints read back with symbol or string keys: show.hints[:comparable_shows].
  def hints
    (super || {}).with_indifferent_access
  end

  def verified?
    verified_at.present?
  end

  # Makes this show the podcast's owner show, proven via one of VERIFIED_VIA: sets verified_at (kept on a second
  # verification) and the podcast's claimed_at, then hands the requests that waited for a claim to the owner
  # (Conversations::ClaimHandoff). Raises AlreadyClaimed when another show owns the podcast; the podcast's row lock and
  # the one-verified-show index keep two verifications from both winning.
  def verify!(via:)
    raise ArgumentError, "unknown verification #{via.inspect}" unless VERIFIED_VIA.include?(via.to_s)

    claimed = false
    transaction(requires_new: true) do
      podcast.lock!
      raise AlreadyClaimed if podcast.shows.where.not(id: id).where.not(verified_at: nil).exists?

      unless verified?
        update!(verified_at: Time.current)
        claimed = true
      end
      podcast.update!(claimed_at: verified_at) if claimed || podcast.claimed_at.nil?
    end
    Conversations::ClaimHandoff.call(podcast) if claimed
    true
  rescue ActiveRecord::RecordNotUnique
    raise AlreadyClaimed
  end

  def public_kit? = verified? && media_kit&.published? || false

  # The shows whose kit is public at /k/:slug: public_kit? as a query (the sitemap lists them).
  scope :with_public_kit, -> { where.not(verified_at: nil).joins(:media_kit).where.not(media_kits: { published_at: nil }) }

  # A queued or running report (only one may be active per show).
  def active_report
    reports.live.order(created_at: :desc, id: :desc).first
  end

  private

  def release_claim
    podcast.update!(claimed_at: nil)
    podcast.refresh_listing!
  end

  def normalize_hints
    raw = self[:hints].is_a?(Hash) ? self[:hints] : {}
    self.hints = HINT_KEYS.index_with do |key|
      list = raw[key] || raw[key.to_sym]
      Array(list.is_a?(Array) ? list : nil).filter_map { |item| item.to_s.strip.first(HINT_LENGTH).strip.presence }.first(HINT_LIMIT)
    end
  end
end
