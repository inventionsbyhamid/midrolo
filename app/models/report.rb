class Report < ApplicationRecord
  KINDS = %w[snapshot agent].freeze
  STATUSES = %w[queued running done failed needs_input].freeze
  ACTIVE = %w[queued running].freeze
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

  # Idempotent per show: a second call (double-click, re-run while running) returns the running report.
  def self.start!(show:, kind:, user:)
    raise Entitlements::NotAllowed, :plan unless Entitlements.for(user).can_run?(kind)

    existing = show.active_report
    return existing if existing

    report = create!(show: show, kind: kind, status: "queued",
                     spend_bucket: (Llm::Budget.bucket_for(user)&.to_s if kind.to_s == "agent"))
    (kind.to_s == "agent" ? GenerateReportJob : BuildSnapshotJob).perform_later(report.id)
    report
  rescue ActiveRecord::RecordNotUnique
    show.active_report || raise
  end

  def active? = status.in?(ACTIVE)
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
    broadcast_replace_to self, target: "report_#{name}", partial: "reports/sections/#{name}",
                                locals: { report: self }
  end
end
