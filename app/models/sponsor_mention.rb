# A sponsor read found in one episode (Sponsors::Scan): which brand, the promo code and offer, and the evidence line.
# published_at is the episode's, copied so sponsor histories need no join.
class SponsorMention < ApplicationRecord
  DETECTORS = %w[pattern llm].freeze
  OFFER_LIMIT = 160
  EVIDENCE_LIMIT = 240

  belongs_to :podcast
  belongs_to :episode
  belongs_to :brand, counter_cache: true

  enum :detected_by, DETECTORS.index_with(&:itself), validate: true, prefix: true

  validates :brand_id, uniqueness: { scope: :episode_id }
  validates :offer, length: { maximum: OFFER_LIMIT }
  validates :evidence, length: { maximum: EVIDENCE_LIMIT }
  validates :confidence, numericality: { in: 0..1 }, allow_nil: true
end
