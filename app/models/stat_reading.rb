# One number about a podcast with where it came from and how far to trust it: from its feed, public, provided by the
# show, or verified with the platform itself. A reading stops counting once it expires (45 days after capture for
# synced ones); the page then says when it was last verified.
class StatReading < ApplicationRecord
  # Least to most trusted.
  TRUST_LEVELS = %w[feed public provided verified].freeze
  DOWNLOADS_PER_EPISODE = "downloads_per_episode".freeze
  # How long a synced reading counts.
  TTL = 45.days

  belongs_to :podcast

  enum :trust, TRUST_LEVELS.index_with(&:itself), validate: true, prefix: true

  validates :metric, :source, :captured_at, presence: true
  validates :value, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :source, uniqueness: { scope: %i[podcast_id metric] }
  validates :period_days, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  scope :unexpired, ->(now = Time.current) { where(expires_at: nil).or(where(expires_at: now..)) }
  scope :expired, ->(now = Time.current) { where(expires_at: ...now) }

  def expired?(now = Time.current) = expires_at.present? && expires_at < now
end
