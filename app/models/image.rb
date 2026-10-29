# A stored picture, artwork first: one row per distinct file (sha256), the file in Active Storage with square webp
# variants made as soon as it is attached (on the artwork queue, config/application.rb). Pages serve the variants
# through rails_storage_proxy URLs, so Cloudflare caches them (podcast_artwork_tag).
class Image < ApplicationRecord
  # Variant name => side in pixels.
  VARIANTS = { thumb: 160, card: 320, page: 640, large: 1280 }.freeze

  has_one_attached :file do |attachable|
    VARIANTS.each do |name, side|
      attachable.variant name, resize_to_fill: [ side, side ], format: :webp, preprocessed: true
    end
  end

  has_many :podcasts, foreign_key: :artwork_image_id, inverse_of: :artwork_image, dependent: :nullify
  has_many :podcast_people, dependent: :nullify

  validates :sha256, presence: true, uniqueness: true, format: { with: /\A\h{64}\z/ }

  scope :visible, -> { where(suppressed_at: nil) }

  # A removal request or an admin took it down: pages show the placeholder instead.
  def visible? = suppressed_at.nil?
end
