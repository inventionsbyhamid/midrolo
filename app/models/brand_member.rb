# A user who runs a brand's account. Verified once they prove a work email at the brand's domain (a 6-digit code;
# the code itself is never stored, only its digest).
class BrandMember < ApplicationRecord
  ROLES = %w[owner member].freeze

  belongs_to :brand
  belongs_to :user

  enum :role, ROLES.index_with(&:itself), validate: true

  validates :user_id, uniqueness: { scope: :brand_id }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :verified, -> { where.not(verified_at: nil) }

  def verified? = verified_at.present?
end
