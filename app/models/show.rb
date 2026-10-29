class Show < ApplicationRecord
  include HasPublicId
  COUNTRIES = { "US" => "United States", "GB" => "United Kingdom", "CA" => "Canada", "AU" => "Australia", "IN" => "India" }.freeze
  HINT_KEYS = %w[comparable_shows topics].freeze
  HINT_LIMIT = 5
  HINT_LENGTH = 100
  SLUG_LENGTH = 60

  belongs_to :user
  has_many :reports, dependent: :destroy
  # Preloadable (includes(:latest_report)) so lists don't N+1.
  has_one :latest_report, -> { order(created_at: :desc, id: :desc) }, class_name: "Report", inverse_of: :show
  has_many :sponsor_matches, dependent: :destroy
  has_one :media_kit, dependent: :destroy
  has_many :verifications, class_name: "ShowVerification", dependent: :destroy

  before_validation :normalize_hints
  # A public kit's share image draws this artwork from storage, fetched off the request path.
  after_update_commit :request_share_artwork, if: -> { saved_change_to_artwork_url? && public_kit? }

  validates :title, presence: true
  validates :country, inclusion: { in: COUNTRIES.keys }
  validates :downloads_per_episode, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :directory_id, uniqueness: { scope: :user_id }, allow_nil: true
  validates :feed_url, uniqueness: { scope: :user_id }, allow_nil: true
  validate :feed_or_directory_present

  # An http(s) URL with a host, or nil, so feed text never reaches an href unchecked.
  def self.http_url(value)
    uri = URI.parse(value.to_s.strip)
    uri.to_s if uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end

  # The title as a slug no other show has: "the-founders-ledger", then "the-founders-ledger-2", and so on.
  def self.free_slug(title)
    base = title.to_s.parameterize.first(SLUG_LENGTH).delete_suffix("-").presence || "show"
    taken = where(slug: base).or(where("slug LIKE ?", "#{sanitize_sql_like(base)}-%")).pluck(:slug).to_set
    return base unless taken.include?(base)

    (2..).lazy.map { |n| "#{base}-#{n}" }.find { |candidate| !taken.include?(candidate) }
  end

  # Hints read back with symbol or string keys: show.hints[:comparable_shows].
  def hints
    (super || {}).with_indifferent_access
  end

  def verified?
    verified_at.present?
  end

  # Marks this show (only this user's copy of the feed) as verified and reserves its public slug. The slug is kept
  # once set. A savepoint lets a slug race with another verification (unique index) retry with the next free slug.
  def verify!
    tries = 0
    begin
      transaction(requires_new: true) do
        self.slug = self.class.free_slug(title) if slug_in_database.blank?
        self.verified_at ||= Time.current
        save!
      end
    rescue ActiveRecord::RecordNotUnique
      raise if (tries += 1) >= 3

      retry
    end
  end

  def public_kit? = verified? && slug.present? && media_kit&.published?

  # The shows whose kit is public at /k/:slug: public_kit? as a query (the sitemap lists them).
  scope :with_public_kit, lambda {
    where.not(verified_at: nil).where.not(slug: nil).joins(:media_kit).where.not(media_kits: { published_at: nil })
  }

  # A queued or running report (only one may be active per show).
  def active_report
    reports.live.order(created_at: :desc, id: :desc).first
  end

  def initials
    letters = title.to_s.split.map { |word| word[/\p{Alnum}/] }.compact.first(2).join.upcase
    letters.presence || "?"
  end

  private

  def request_share_artwork = ShareImages::ArtworkStore.request(self)

  def normalize_hints
    raw = self[:hints].is_a?(Hash) ? self[:hints] : {}
    self.hints = HINT_KEYS.index_with do |key|
      list = raw[key] || raw[key.to_sym]
      Array(list.is_a?(Array) ? list : nil).filter_map { |item| item.to_s.strip.first(HINT_LENGTH).strip.presence }.first(HINT_LIMIT)
    end
  end

  def feed_or_directory_present
    errors.add(:feed_url, "can't be blank") if feed_url.blank? && directory_id.blank?
  end
end
