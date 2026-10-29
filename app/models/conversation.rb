# A brand asking a podcast for a spot: format, months and budget, then messages. On an unclaimed podcast it waits for
# the claim (and is never emailed to the feed owner); Conversations::ClaimHandoff opens it when the show is claimed.
# Deleting an account keeps the other party's copy: user links are nullified.
#
# Two sides read a conversation (side_for): the podcast's owner (the user whose show is verified) and the brand. On the
# brand side, a verified member sees every conversation of the brand; an unverified member only those they started, so
# signing up as a brand's name never opens its inbox. Each side has a read mark (podcaster_read_at, brand_read_at): a
# side is behind when the conversation changed (updated_at: a message, an answer, a close) after its mark.
class Conversation < ApplicationRecord
  include HasPublicId

  STATUSES = %w[waiting_for_claim open accepted declined closed].freeze
  # At most one of these per podcast and brand (a partial unique index).
  ONGOING = %w[waiting_for_claim open].freeze
  # Where people can still write. A waiting one only has the brand: the podcaster hasn't arrived yet.
  WRITABLE = %w[waiting_for_claim open accepted].freeze
  SIDES = %i[podcaster brand].freeze
  # Why an answer or a close didn't happen, by the status it found.
  FINAL_NOTES = {
    "waiting_for_claim" => "This request is waiting for the show to claim its page.",
    "accepted" => "This request was already accepted.",
    "declined" => "This request was already declined.",
    "closed" => "This conversation is closed."
  }.freeze
  MONTHS_LIMIT = 12
  DECLINE_REASON_LIMIT = 500

  # An answer or a close the conversation's state no longer allows (it was answered or closed in another tab).
  class InvalidTransition < StandardError; end

  belongs_to :podcast
  belongs_to :brand
  belongs_to :started_by, class_name: "User", optional: true
  has_many :messages, -> { order(:created_at, :id) }, dependent: :delete_all, inverse_of: :conversation

  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :format, inclusion: { in: MediaKit::RATE_SLOTS.keys }, allow_blank: true
  validates :budget_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :decline_reason, length: { maximum: DECLINE_REASON_LIMIT }
  validates :decline_reason, presence: true, if: :declined?
  validates :months, length: { maximum: MONTHS_LIMIT }
  validate :months_are_months

  scope :ongoing, -> { where(status: ONGOING) }
  scope :latest_first, -> { order(Arel.sql("conversations.last_message_at DESC NULLS LAST"), id: :desc) }
  # The podcaster side: conversations about podcasts the user owns (their verified shows). A waiting one has no
  # podcaster yet (the claim opens it).
  scope :for_podcaster, lambda { |user|
    where(podcast_id: Show.where(user_id: user.id).where.not(verified_at: nil).select(:podcast_id))
      .where.not(status: "waiting_for_claim")
  }
  # The brand side: every conversation of a brand the user is a verified member of, and those they started for a
  # brand they're an unverified member of.
  scope :for_brand_user, lambda { |user|
    memberships = BrandMember.where(user_id: user.id)
    where(brand_id: memberships.select(:brand_id), started_by_id: user.id)
      .or(where(brand_id: memberships.verified.select(:brand_id)))
  }
  # Everything the user may open, from either side.
  scope :visible_to, ->(user) { for_podcaster(user).or(for_brand_user(user)) }
  scope :unread_by_podcaster, lambda {
    where("conversations.podcaster_read_at IS NULL OR conversations.podcaster_read_at < conversations.updated_at")
  }
  scope :unread_by_brand, lambda {
    where("conversations.brand_read_at IS NULL OR conversations.brand_read_at < conversations.updated_at")
  }

  def months=(value)
    super(Array(value).map { |month| month.to_s.strip }.compact_blank.uniq.sort)
  end

  # :podcaster when the user owns the podcast, :brand when they're on the brand side (see for_brand_user), else nil.
  def side_for(user)
    return nil unless user
    return :podcaster if !waiting_for_claim? && Show.where(podcast_id: podcast_id, user_id: user.id).where.not(verified_at: nil).exists?

    memberships = BrandMember.where(user_id: user.id, brand_id: brand_id)
    :brand if memberships.verified.exists? || (started_by_id == user.id && memberships.exists?)
  end

  def writable? = WRITABLE.include?(status)

  # True when this side hasn't seen the latest change.
  def unread_for?(side)
    read_at = read_at_for(side)
    read_at.nil? || read_at < updated_at
  end

  # The side has seen everything up to now.
  def mark_read!(side)
    update_columns(read_column(side) => [ Time.current, updated_at ].compact.max)
  end

  # Whether whoever asked proved a work email at the brand's domain (BrandMember#verified?). Requests from anyone else
  # carry the "Unverified brand" label. Reads started_by's memberships, so lists preload started_by: :brand_members.
  def from_verified_brand?
    return false unless started_by

    started_by.brand_members.any? { |member| member.brand_id == brand_id && member.verified? }
  end

  # The podcaster's answers to an open request. Each records the first reply, keeps the podcaster's read mark and
  # leaves the brand behind (unread). Raises InvalidTransition when the request isn't open, and RecordInvalid for a
  # decline without a reason.
  def accept! = answer!(status: "accepted")

  def decline!(reason:) = answer!(status: "declined", decline_reason: reason.to_s.squish.presence)

  # Either side ends it (a brand withdraws its request). Raises InvalidTransition once it's final.
  def close!(by:)
    change_status!(by, status: "closed", closed_at: Time.current) { writable? }
  end

  # Marks the conversation for an admin to look at (the first report counts; later ones change nothing). Returns true
  # for the first.
  def report!
    return false if reported_at

    update_columns(reported_at: Time.current)
    true
  end

  # The podcaster's first answer: a message, an accept or a decline.
  def record_reply!(at: Time.current)
    update_columns(first_reply_at: at) if first_reply_at.nil?
  end

  private

  def read_column(side)
    raise ArgumentError, "unknown side #{side.inspect}" unless SIDES.include?(side)

    "#{side}_read_at"
  end

  def read_at_for(side) = self[read_column(side)]

  def answer!(**attributes)
    change_status!(:podcaster, **attributes) { open? }
  end

  # Applies attributes under a row lock when the block (checked on the locked row) allows it.
  def change_status!(side, **attributes)
    read_column(side) # an unknown side raises before anything changes
    transaction do
      lock!
      raise InvalidTransition, FINAL_NOTES.fetch(status, "This request can't change now.") unless yield

      now = Time.current
      update!(**attributes, updated_at: now)
      record_reply!(at: now) if side == :podcaster
      mark_read!(side)
    end
    true
  end

  def months_are_months
    errors.add(:months, "must be calendar months") unless months.all? { |month| month.to_s.match?(MediaKit::MONTH) }
  end
end
