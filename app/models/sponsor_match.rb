class SponsorMatch < ApplicationRecord
  STATUSES = %w[suggested saved pitched replied won lost].freeze

  belongs_to :report
  belongs_to :show

  enum :status, STATUSES.index_with(&:itself), default: "suggested", validate: true

  validates :brand_entity_id, presence: true, uniqueness: { scope: :report_id }
end
