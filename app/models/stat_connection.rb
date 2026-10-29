# A podcast's link to a platform that measures it (build spec section 11): the podcaster invites Midrolo's service
# account to their Spotify or Apple analytics, and Stats::SyncJob reads the numbers through Stats::PlatformFetch.
# Readings count only while the podcast is claimed by the user who made the connection and the platform's show matches
# the podcast; otherwise the status says why. credentials is generic and encrypted, for connectors that need their own.
class StatConnection < ApplicationRecord
  # spotify and apple are this slice's; the rest are kept for later connectors.
  PROVIDERS = %w[spotify apple op3 transistor buzzsprout youtube spotify_upload apple_upload].freeze
  STATUSES = %w[pending_invite active mismatch failed disconnected].freeze
  # How long a pending invite is polled before it gives up.
  INVITE_WINDOW = 14.days

  belongs_to :podcast
  belongs_to :show, optional: true
  belongs_to :user, optional: true

  # A private upload (an export or a screenshot): only the owner and admins open it, never through a public URL.
  has_one_attached :evidence_file

  encrypts :credentials

  enum :provider, PROVIDERS.index_with(&:itself), validate: true
  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :provider, uniqueness: { scope: :podcast_id }
  validates :external_id, length: { maximum: 200 }
end
