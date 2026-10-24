class Report < ApplicationRecord
  KINDS = %w[snapshot agent].freeze
  STATUSES = %w[queued running done failed needs_input].freeze
  ACTIVE = %w[queued running].freeze
  # A run that has not finished in this long is presumed dead (killed worker, lost job).
  STALE_AFTER = 15.minutes
  SECTIONS = %w[summary seeds audience leans map matches].freeze
  # Report column behind each section (leans come from demographics, map from heatmap).
  SECTION_COLUMNS = { "summary" => :summary, "seeds" => :seeds, "audience" => :audience,
                      "leans" => :demographics, "map" => :heatmap }.freeze
  FAILURE_MESSAGE = "Something went wrong while researching. Nothing was charged — try again.".freeze
  STATUS_COPY = { "queued" => "Getting started…", "running" => "Researching your audience…", "done" => "Report ready",
                  "failed" => "Something went wrong", "needs_input" => "Needs a little more info" }.freeze

  belongs_to :show
  has_many :agent_steps, -> { order(:position, :id) }, dependent: :destroy
  has_many :sponsor_matches, -> { order(:position) }, dependent: :destroy

  enum :kind, KINDS.index_with(&:itself), validate: true
  enum :status, STATUSES.index_with(&:itself), validate: true
  enum :profile_kind, { direct: "direct", proxy: "proxy" }, validate: { allow_nil: true }

  scope :active, -> { where(status: ACTIVE) }
  scope :stale, lambda {
    cutoff = STALE_AFTER.ago
    where(status: "running").where(started_at: ...cutoff).or(where(status: "queued").where(created_at: ...cutoff))
  }
  # Active and still plausibly alive.
  scope :live, -> { active.where.not(id: stale.select(:id)) }

  after_update_commit :broadcast_status_refresh, if: :saved_change_to_status?

  # Idempotent per show: a second call (double-click, re-run while running) returns the running report,
  # before any entitlement check. Stale active reports are failed first so they can't block the show.
  def self.start!(show:, kind:, user:)
    existing = show.active_report
    return existing if existing

    raise Entitlements::NotAllowed, :plan unless Entitlements.for(user).can_run?(kind)

    report = transaction do
      show.reports.stale.find_each { |stale| stale.mark_failed! }
      create!(show: show, kind: kind, status: "queued",
              spend_bucket: (Llm::Budget.bucket_for(user)&.to_s if kind.to_s == "agent"))
    end
    (kind.to_s == "agent" ? GenerateReportJob : BuildSnapshotJob).perform_later(report.id)
    report
  rescue ActiveRecord::RecordNotUnique
    show.active_report || raise
  end

  def active? = status.in?(ACTIVE)

  # The seeds section as Research::Tools::SaveTasteSeeds saves it:
  #   {"entities" => [{id, name, type, source}], "tags" => [{id, name, source}], "unresolved" => [names]}
  def seed_items = seeds.is_a?(Hash) ? Array(seeds["entities"]) + Array(seeds["tags"]) : []
  def unresolved_seeds = seeds.is_a?(Hash) ? Array(seeds["unresolved"]) : []
  def status_copy = STATUS_COPY.fetch(status)

  def mark_running!
    update!(status: "running", started_at: Time.current)
  end

  def mark_done!
    update!(status: "done", finished_at: Time.current)
  end

  def mark_needs_input!
    update!(status: "needs_input", finished_at: Time.current)
  end

  def mark_failed!(message = FAILURE_MESSAGE)
    update!(status: "failed", finished_at: Time.current, error_message: message)
  end

  # Saves one section and pushes it to open report pages. Matches live in their own table, so
  # save_section!(:matches, nil) just re-renders the list.
  def save_section!(name, data = nil)
    name = name.to_s
    raise ArgumentError, "unknown section #{name}" unless SECTIONS.include?(name)

    update!(SECTION_COLUMNS.fetch(name) => data) if SECTION_COLUMNS.key?(name)
    sponsor_matches.reset if name == "matches" # the partial reads the association; drop any stale copy
    broadcast_replace_to self, target: "report_#{name}", partial: "reports/sections/#{name}",
                                locals: { report: self }
  end

  private

  # Open report pages re-render (morphed) so the badge, Re-run button and failed/needs_input cards follow.
  def broadcast_status_refresh
    broadcast_refresh_to(self)
  end
end
