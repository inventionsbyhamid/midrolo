# A person the podcast's feed names (podcast:person, itunes:author): only those, never anyone else. Ingest upserts
# them by (podcast, name_key, role).
class PodcastPerson < ApplicationRecord
  ROLES = %w[host guest other].freeze

  belongs_to :podcast
  belongs_to :image, optional: true

  enum :role, ROLES.index_with(&:itself), validate: true

  before_validation :assign_name_key

  validates :name, :name_key, presence: true
  validates :name_key, uniqueness: { scope: %i[podcast_id role] }

  # "Dr. Elena Cruz" and "dr elena cruz" are one person.
  def self.name_key_for(name) = Research::Names.normalize(name)

  private

  def assign_name_key
    self.name_key = self.class.name_key_for(name) if name.present?
  end
end
