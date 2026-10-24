class SponsorMatch < ApplicationRecord
  STATUSES = %w[suggested saved pitched replied won lost].freeze
  # The podcaster's pipeline, in order: every status past "suggested".
  PIPELINE_STATUSES = (STATUSES - %w[suggested]).freeze
  # A won or lost deal has no follow-up to chase.
  CLOSED_STATUSES = %w[won lost].freeze
  NOTES_LIMIT = 2_000
  # A date input left half-typed can submit a year like 0002; nobody follows up outside these years.
  FOLLOW_UP_YEARS = 2000..2100
  # The order a report lists its matches in (Report#sponsor_matches), and so the order the plan's visible limit
  # counts in (R43). REPORT_RANK_SQL numbers each match in that order within its report, from 1.
  IN_REPORT_ORDER = %i[position id].freeze
  REPORT_RANK_SQL = "ROW_NUMBER() OVER (PARTITION BY sponsor_matches.report_id " \
                    "ORDER BY #{IN_REPORT_ORDER.map { |column| "sponsor_matches.#{column}" }.join(', ')})".freeze

  belongs_to :report
  belongs_to :show

  enum :status, STATUSES.index_with(&:itself), default: "suggested", validate: true

  normalizes :notes, with: ->(notes) { notes.strip.presence }

  validates :brand_entity_id, presence: true, uniqueness: { scope: :report_id }
  validates :notes, length: { maximum: NOTES_LIMIT, message: "can be at most %{count} characters" }
  validate :follow_up_on_is_a_date

  # Brings the podcaster's pipeline work onto a new report's matches (R46a). Each match still at its defaults takes
  # status, notes and follow-up date, as a unit, from its brand's copy that counts on the show's earlier reports
  # (Pipeline::Matches: the newest, never a locked one), so whatever the podcaster cleared stays cleared. A match the
  # plan locks (R43) gets nothing, so a locked brand never reaches the pipeline.
  def self.carry_forward!(report)
    targets = report.sponsor_matches.reload.select(&:at_defaults?)
    return if targets.empty?

    sources = Pipeline::Matches.earlier_copies(report, brand_entity_ids: targets.map(&:brand_entity_id))
    plan = Entitlements.for(report.show.user)
    transaction do
      targets.each do |target|
        source = sources[target.brand_entity_id]
        next if source.nil? || target.locked?(plan)

        target.update!(status: source.status, notes: source.notes, follow_up_on: source.follow_up_on)
      end
    end
  end

  # SQL twin of locked? (false there, true here), for a relation selecting report_kind and report_rank
  # (Pipeline::Matches). The limit is read when the query runs, so it follows plan changes.
  def self.unlocked_sql(limit)
    sanitize_sql_array([ "NOT (sponsor_matches.report_kind = 'snapshot' AND sponsor_matches.report_rank > ?)", limit ])
  end

  # Untouched by the podcaster (or by an earlier carry-forward).
  def at_defaults? = suggested? && notes.nil? && follow_up_on.nil?

  # :overdue, :today or :upcoming against Date.current; nil without a follow-up date.
  def follow_up_state
    return unless follow_up_on

    today = Date.current
    return :today if follow_up_on == today

    follow_up_on < today ? :overdue : :upcoming
  end

  # :overdue or :today when an open deal's follow-up needs doing; nil otherwise, and always for won or lost.
  def follow_up_alert
    state = follow_up_state
    state if state.in?(%i[overdue today]) && !status.in?(CLOSED_STATUSES)
  end

  # True for a Snapshot match past the plan's visible limit, in report order: the report shows it blurred with
  # nothing about the brand (R43), so nothing may change or reveal it. Agent reports are always fully visible (R44).
  # unlocked_sql states the same rule in SQL.
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
