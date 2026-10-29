# Midrolo's own service account's session on a platform (Spotify for Creators, Apple Podcasts Connect), entered by an
# admin and used by Stats::PlatformFetch. The credentials are encrypted, never shown again after saving, and never put
# in job arguments, logs or exceptions (Rails filters encrypted attributes from both). A fetch that finds them expired
# marks the session expired, and syncs pause until an admin updates it.
class ServiceSession < ApplicationRecord
  PLATFORMS = %w[spotify apple].freeze
  STATUSES = %w[ok expired].freeze

  encrypts :credentials

  enum :platform, PLATFORMS.index_with(&:itself), validate: true
  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :platform, uniqueness: true
end
