# One episode as the podcast's feed describes it. Ingest upserts the newest 50 on every fetch (upsert_all, so no
# callbacks) and never deletes any in this slice; the slug is set on insert only, from Episode.slug_for.
class Episode < ApplicationRecord
  DESCRIPTION_LIMIT = 4000
  SLUG_LENGTH = 60

  belongs_to :podcast
  has_many :sponsor_mentions, dependent: :delete_all

  normalizes :description, with: ->(text) { text.strip.truncate(DESCRIPTION_LIMIT).presence }

  before_validation :assign_slug, on: :create

  validates :guid, :slug, :title, presence: true
  validates :guid, uniqueness: { scope: :podcast_id }
  validates :slug, uniqueness: { scope: :podcast_id }

  scope :newest_first, -> { order(published_at: :desc, id: :desc) }

  # The title, parameterized and capped at 60 characters, then 6 hex of the guid's SHA256: stable for the episode
  # whatever its title becomes, and unique within the podcast in practice.
  def self.slug_for(title, guid)
    base = title.to_s.parameterize.first(SLUG_LENGTH).delete_suffix("-").presence || "episode"
    "#{base}-#{Digest::SHA256.hexdigest(guid.to_s).first(6)}"
  end

  def to_param = slug_in_database

  private

  def assign_slug
    self.slug ||= self.class.slug_for(title, guid) if guid.present?
  end
end
