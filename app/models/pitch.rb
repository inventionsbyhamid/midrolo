# One pitch pack for a match (spec §5.5), written by GeneratePitchJob: queued, then done or failed. Regenerate makes a
# new row; the dialog shows the match's newest. Only done pitches count toward the plan's pitch limit (R50).
class Pitch < ApplicationRecord
  STATUSES = %w[queued done failed].freeze
  # What Pitches::Writer returns, one column each.
  FIELDS = %w[subject body angles offer follow_up contact_role].freeze
  # A pitch queued for longer than this is presumed lost (killed worker): it shows as failed and can be retried.
  STALE_AFTER = 15.minutes
  FAILURE_MESSAGE = "Something went wrong while writing this pitch. It wasn't counted — try again.".freeze
  PAUSED_MESSAGE = "Pitches are paused right now — try again later.".freeze
  UNGROUNDED_MESSAGE = "We couldn't ground this pitch in your data — try again".freeze

  belongs_to :sponsor_match

  enum :status, STATUSES.index_with(&:itself), default: "queued", validate: true

  # Usage: what the plan's pitch limit counts (Task 16).
  scope :counted, -> { done }
  # Being written, not yet stale: reserved against the plan's limit until it's done or failed (R53).
  scope :in_flight, -> { queued.where(created_at: STALE_AFTER.ago..) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  # The dialog showing this pitch follows it from queued to done or failed.
  after_update_commit :broadcast_result, if: -> { saved_change_to_status? && !queued? }

  def stale? = queued? && created_at < STALE_AFTER.ago

  # Still being written: a second request reuses it instead of starting another.
  def in_flight? = queued? && !stale?

  def word_count = body.to_s.split.size

  # A pitch that went stale while it was written already shows as failed, so it stays failed and uncounted.
  def complete!(attributes, model:)
    return mark_failed! if stale?

    update!(attributes.slice(*FIELDS).merge(status: "done", model: model, cost_usd: spent, error_message: nil))
  end

  def mark_failed!(message = FAILURE_MESSAGE)
    update!(status: "failed", error_message: message, cost_usd: spent)
  end

  private

  # What this pitch's model calls cost us (a corrective retry included), for margin reporting; never a charge.
  def spent = SpendEntry.where(pitch_id: id).sum(:cost_usd)

  def broadcast_result
    broadcast_replace_to self, target: ActionView::RecordIdentifier.dom_id(self), partial: "pitches/pitch",
                               locals: { pitch: self }
  end
end
