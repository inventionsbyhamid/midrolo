# A brand asking a podcast for a spot: format, months and budget, then messages. On an unclaimed podcast it waits for
# the claim (and is never emailed to the feed owner); Conversations::ClaimHandoff opens it when the show is claimed.
# Deleting an account keeps the other party's copy: user links are nullified.
class Conversation < ApplicationRecord
  include HasPublicId

  STATUSES = %w[waiting_for_claim open accepted declined closed].freeze
  # At most one of these per podcast and brand (a partial unique index).
  ONGOING = %w[waiting_for_claim open].freeze

  belongs_to :podcast
  belongs_to :brand
  belongs_to :started_by, class_name: "User", optional: true
  has_many :messages, -> { order(:created_at, :id) }, dependent: :delete_all, inverse_of: :conversation

  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :budget_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :decline_reason, length: { maximum: 500 }

  scope :ongoing, -> { where(status: ONGOING) }

  def months=(value)
    super(Array(value).map { |month| month.to_s.strip }.compact_blank.uniq)
  end
end
