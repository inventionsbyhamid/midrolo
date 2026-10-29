# A podcast on a brand's saved list. user is who saved it (nullified when their account goes; the list is the brand's).
class SavedPodcast < ApplicationRecord
  NOTE_LIMIT = 500

  belongs_to :brand
  belongs_to :podcast
  belongs_to :user, optional: true

  validates :podcast_id, uniqueness: { scope: :brand_id }
  validates :note, length: { maximum: NOTE_LIMIT }
end
