class SponsorMatch < ApplicationRecord
  STATUSES = %w[suggested saved pitched replied won lost].freeze
  # The podcaster's pipeline, in order: every status past "suggested".
  PIPELINE_STATUSES = (STATUSES - %w[suggested]).freeze
  NOTES_LIMIT = 2_000
  # A date input left half-typed can submit a year like 0002; nobody follows up outside these years.
  FOLLOW_UP_YEARS = 2000..2100

  belongs_to :report
  belongs_to :show

  enum :status, STATUSES.index_with(&:itself), default: "suggested", validate: true

  normalizes :notes, with: ->(notes) { notes.strip.presence }

  validates :brand_entity_id, presence: true, uniqueness: { scope: :report_id }
  validates :notes, length: { maximum: NOTES_LIMIT, message: "can be at most %{count} characters" }
  validate :follow_up_on_is_a_date

  # Matches holding any of the podcaster's pipeline work: a status, notes or a follow-up date.
  scope :tracked, -> { where.not(status: "suggested").or(where.not(notes: nil)).or(where.not(follow_up_on: nil)) }

  # Copies the podcaster's pipeline work from an earlier report's matches onto the same brands (by
  # brand_entity_id) on a newer report (R46). Only fields set on the source are copied, and a field already set on
  # the target is never overwritten, so a second call changes nothing and edits made on the new report stay.
  def self.carry_forward!(from_report, to_report)
    sources = from_report.sponsor_matches.tracked.index_by(&:brand_entity_id)
    return if sources.empty?

    transaction do
      to_report.sponsor_matches.where(brand_entity_id: sources.keys).each do |target|
        target.carry_from(sources.fetch(target.brand_entity_id))
      end
    end
  end

  def carry_from(source)
    self.status = source.status if suggested? && !source.suggested?
    self.notes = source.notes if notes.blank? && source.notes.present?
    self.follow_up_on = source.follow_up_on if follow_up_on.nil? && source.follow_up_on
    save! if changed?
  end

  # :overdue, :today or :upcoming against Date.current; nil without a follow-up date.
  def follow_up_state
    return unless follow_up_on

    today = Date.current
    return :today if follow_up_on == today

    follow_up_on < today ? :overdue : :upcoming
  end

  # True for a Snapshot match past the plan's visible limit, by position: the report shows it blurred with nothing
  # about the brand (R43), so nothing may change or reveal it. Agent reports are always fully visible (R44).
  def locked?(plan)
    return false unless report.snapshot?

    rank = report.sponsor_matches.ids.index(id)
    rank.nil? || rank >= plan.visible_matches_limit
  end

  private

  # Rails casts an impossible date ("2026-13-45") to nil, which would silently clear the field.
  def follow_up_on_is_a_date
    if follow_up_on.nil?
      errors.add(:follow_up_on, "isn't a valid date") if follow_up_on_before_type_cast.present?
    elsif !FOLLOW_UP_YEARS.cover?(follow_up_on.year)
      errors.add(:follow_up_on, "isn't a valid date")
    end
  end
end
