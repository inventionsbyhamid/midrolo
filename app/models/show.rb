class Show < ApplicationRecord
  COUNTRIES = { "US" => "United States", "GB" => "United Kingdom", "CA" => "Canada", "AU" => "Australia", "IN" => "India" }.freeze
  HINT_KEYS = %w[comparable_shows topics].freeze
  HINT_LIMIT = 5
  HINT_LENGTH = 100

  belongs_to :user
  has_many :reports, dependent: :destroy
  # Preloadable (includes(:latest_report)) so lists don't N+1.
  has_one :latest_report, -> { order(created_at: :desc, id: :desc) }, class_name: "Report", inverse_of: :show
  has_many :sponsor_matches, dependent: :destroy

  before_validation :normalize_hints

  validates :title, presence: true
  validates :country, inclusion: { in: COUNTRIES.keys }
  validates :downloads_per_episode, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :directory_id, uniqueness: { scope: :user_id }, allow_nil: true
  validates :feed_url, uniqueness: { scope: :user_id }, allow_nil: true
  validate :feed_or_directory_present

  # Hints read back with symbol or string keys: show.hints[:comparable_shows].
  def hints
    (super || {}).with_indifferent_access
  end

  def verified?
    verified_at.present?
  end

  # A queued or running report (only one may be active per show).
  def active_report
    reports.live.order(created_at: :desc, id: :desc).first
  end

  def initials
    letters = title.to_s.split.map { |word| word[/\p{Alnum}/] }.compact.first(2).join.upcase
    letters.presence || "?"
  end

  private

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
