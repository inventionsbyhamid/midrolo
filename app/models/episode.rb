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

  # A readable slug for an episode, unique within its podcast: the title parameterized ("the-spy"). taken is the set of
  # slugs the podcast already uses (pass it from a batch insert, adding each slug as it is given out); a clash takes
  # 6 hex of the guid's SHA256, then a number. Without taken (nothing to check against), the guid suffix keeps it unique.
  def self.slug_for(title, guid, taken: nil)
    base = title.to_s.parameterize.first(SLUG_LENGTH).delete_suffix("-").presence || "episode"
    hashed = "#{base.first(SLUG_LENGTH - 7)}-#{Digest::SHA256.hexdigest(guid.to_s).first(6)}"
    return hashed if taken.nil?

    [ base, hashed ].find { |slug| !taken.include?(slug) && !FriendlySlug::RESERVED.include?(slug) } ||
      (2..).lazy.map { |n| "#{hashed}-#{n}" }.find { |slug| !taken.include?(slug) }
  end

  def to_param = slug_in_database

  private

  def assign_slug
    return if slug.present? || guid.blank?

    taken = self.class.where(podcast_id: podcast_id).pluck(:slug).to_set if podcast_id
    self.slug = self.class.slug_for(title, guid, taken: taken)
  end
end
