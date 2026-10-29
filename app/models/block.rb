# A brand a podcast's owner blocked: its requests to that podcast stop.
class Block < ApplicationRecord
  belongs_to :podcast
  belongs_to :brand

  validates :brand_id, uniqueness: { scope: :podcast_id }
end
