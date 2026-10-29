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
  # The statuses that hold a platform show, so it backs one Midrolo page (a partial unique index backs the
  # validation): every one but disconnected.
  HOLDING_STATUSES = (STATUSES - %w[disconnected]).freeze
  # A connection another podcast's owner may take a platform show from: never verified, and made by someone who
  # doesn't own its podcast (release_unowned!).
  RELEASABLE_STATUSES = %w[pending_invite mismatch failed].freeze
  TAKEN_MESSAGE = "This show is already connected to another Midrolo page.".freeze
  RELEASED_MESSAGE = "The show's owner connected it to their own Midrolo page, so this connection stopped.".freeze
  # An admin's Reject on a connection held for review (Stats::RejectConnection). Names no show, like the one above.
  REJECTED_MESSAGE = "Midrolo checked this connection by hand and couldn't confirm that show is this podcast, so it " \
                     "stopped. Paste your own show's link to connect again.".freeze

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
  validate :platform_show_free, if: :claims_platform_show?

  # Connections to this platform show on other podcasts that never counted (pending, mismatched or failed, never
  # active) and whose maker doesn't own that podcast are disconnected: the owner connecting their own show takes it
  # over, so a draft workspace can't hold someone else's show. Their maker sees RELEASED_MESSAGE, which names no show.
  def self.release_unowned!(provider:, external_id:, except_podcast_id:)
    where(provider: provider, external_id: external_id, status: RELEASABLE_STATUSES, activated_at: nil)
      .where.not(podcast_id: except_podcast_id).includes(podcast: :owner_show).find_each do |connection|
        owner_id = connection.podcast.owner_show&.user_id
        next if owner_id.present? && owner_id == connection.user_id

        connection.update!(status: "disconnected", last_error: RELEASED_MESSAGE)
      end
  end

  # Disconnected by Midrolo (another page's owner took the platform show, or an admin rejected it), not by the
  # platform: the Stats screen says why instead of "access was removed".
  def stopped_by_midrolo? = disconnected? && last_error.in?([ RELEASED_MESSAGE, REJECTED_MESSAGE ])

  # Another podcast's connection (in any state but disconnected) holds this platform show.
  def platform_show_taken?
    external_id.present? &&
      self.class.where(provider: provider, external_id: external_id, status: HOLDING_STATUSES).where.not(id: id).exists?
  end

  private

  def claims_platform_show?
    external_id.present? && status.in?(HOLDING_STATUSES) &&
      (new_record? || will_save_change_to_status? || will_save_change_to_external_id? || will_save_change_to_provider?)
  end

  def platform_show_free
    errors.add(:base, TAKEN_MESSAGE) if platform_show_taken?
  end
end
