# Something kept out of the catalog for good, so a re-seed or a search can't bring it back: a podcast (by its
# podcast:guid or its feed URL's digest) or an image (by its sha256).
class Suppression < ApplicationRecord
  KINDS = %w[podcast image].freeze

  enum :kind, KINDS.index_with(&:itself), validate: true

  validates :value, presence: true, uniqueness: { scope: :kind }

  # The SHA256 of a feed URL as the catalog keys it (Podcast.normalize_feed_url).
  def self.feed_digest(feed_url) = Digest::SHA256.hexdigest(Podcast.normalize_feed_url(feed_url).to_s)

  # Whether a podcast with this guid or feed URL is suppressed.
  def self.podcast?(guid: nil, feed_url: nil)
    values = [ guid.presence, (feed_digest(feed_url) if feed_url.present?) ].compact
    values.any? && podcast.exists?(value: values)
  end

  def self.image?(sha256) = sha256.present? && image.exists?(value: sha256)
end
