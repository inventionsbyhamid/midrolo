class Report < ApplicationRecord
  include HasPublicId
  KINDS = %w[snapshot agent].freeze
  STATUSES = %w[queued running done failed needs_input].freeze
  ACTIVE = %w[queued running].freeze
  # A run that has not finished in this long is presumed dead (killed worker, lost job).
  STALE_AFTER = 15.minutes
  SECTIONS = %w[summary seeds audience leans map matches].freeze
  # Report column behind each section (leans come from demographics, map from heatmap).
  SECTION_COLUMNS = { "summary" => :summary, "seeds" => :seeds, "audience" => :audience,
                      "leans" => :demographics, "map" => :heatmap }.freeze
  FAILURE_MESSAGE = "Something went wrong while researching. Nothing was charged. Try again.".freeze
  STATUS_COPY = { "queued" => "Getting started…", "running" => "Researching your audience…", "done" => "Report ready",
                  "failed" => "Something went wrong", "needs_input" => "Needs a little more info" }.freeze
  # The summary is the At a glance box's bullets (R99): at most this many, each one plain sentence of at most this
  # many words. Research::Tools::SaveSummary holds the agent to it.
  SUMMARY_POINTS = 3
  SUMMARY_POINT_WORDS = 20
  SUMMARY_POINT_LENGTH = 160
  # The audience section's lists, as people read them, in the order they show: the interests describe the audience
  # best. The report and the media kit both label their taste chips and lists with these.
  AUDIENCE_LABELS = { "tags" => "Interests", "brands" => "Brands", "podcasts" => "Podcasts", "tv_shows" => "TV",
                      "artists" => "Music" }.freeze

  # Qloo has near twins under different ids (Cybercrime twice, "cyber crime", Hacker and Hackers), so a taste list
  # shows each name once: the first, which is the strongest.
  def self.distinct_tastes(items) = items.uniq { |item| item["name"].to_s.downcase.gsub(/[^[:alnum:]]/, "").delete_suffix("s") }

  belongs_to :show
  has_many :agent_steps, -> { order(:position, :id) }, dependent: :destroy
  # In the order the report lists them, which is also the order the plan's visible limit counts in (R43).
  has_many :sponsor_matches, -> { order(*SponsorMatch::IN_REPORT_ORDER) }, dependent: :destroy

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
  # before any entitlement check. Otherwise the plan's gate and the insert run under the user's usage lock, so
  # parallel starts on the user's shows can't overshoot the plan (R61). Raises Entitlements::NotAllowed with the
  # plan's reason.
  def self.start!(show:, kind:, user:)
    existing = show.active_report
    return existing if existing

    created = nil
    report = transaction do
      Entitlements.lock_usage!(user)
      # A start for this show that held the lock first (a double-click) already made the report: return that one.
      show.active_report || (created = create_queued!(show: show, kind: kind, plan: Entitlements.for(user)))
    end
    (kind.to_s == "agent" ? GenerateReportJob : BuildSnapshotJob).perform_later(created.id) if created
    report
  rescue ActiveRecord::RecordNotUnique
    show.active_report || raise
  end

  # Stale active reports are failed first so they can't block the show.
  def self.create_queued!(show:, kind:, plan:)
    plan.authorize!(kind)
    show.reports.stale.find_each { |stale| stale.mark_failed! }
    create!(show: show, kind: kind, status: "queued", spend_bucket: (plan.spend_bucket&.to_s if kind.to_s == "agent"))
  end
  private_class_method :create_queued!

  def active? = status.in?(ACTIVE)

  # The seeds section as Research::Tools::SaveTasteSeeds saves it:
  #   {"entities" => [{id, name, type, source}], "tags" => [{id, name, source}], "unresolved" => [names]}
  def seed_items = seeds.is_a?(Hash) ? Array(seeds["entities"]) + Array(seeds["tags"]) : []
  def unresolved_seeds = seeds.is_a?(Hash) ? Array(seeds["unresolved"]) : []
  def status_copy = STATUS_COPY.fetch(status)

  # The summary's bullets, one a line as SaveSummary saves them; none for an older prose summary.
  def summary_points
    legacy_summary? ? [] : summary_lines.first(SUMMARY_POINTS)
  end

  # A summary saved before R1 (R103): prose, with a line longer than any bullet SaveSummary would save.
  def legacy_summary? = summary_lines.any? { |line| line.split.size > SUMMARY_POINT_WORDS }

  # An older prose summary's sentences, without a leading "Built from…" one (How we built this says where the profile
  # came from), to show as plain text rather than in At a glance's labelled lines (R103).
  def legacy_summary_sentences
    return [] unless legacy_summary?

    sentences = Llm::PlainText.sentences(summary_lines.join(" "))
    sentences.first&.start_with?("Built from") ? sentences.drop(1) : sentences
  end

  def summary_lines = summary.to_s.lines.map(&:strip).compact_blank

  def mark_running!
    update!(status: "running", started_at: Time.current)
  end

  # Moves a queued report to running for the job that claims it (R135): true for that one claim, so a job delivered
  # twice (at-least-once) runs the research once. Open report pages refresh as for any status change.
  def claim_start!
    now = Time.current
    claimed = self.class.where(id: id, status: "queued").update_all(status: "running", started_at: now, updated_at: now)
    return false unless claimed == 1

    reload
    broadcast_status_refresh
    true
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

  # A full report's outcomes that mail its owner (ReportMailJob, R113): ready, or waiting on comparable shows. Each
  # names the column that claims its mail. A failed report sends nothing.
  MAILED_OUTCOMES = { "done" => :ready_mailed_at, "needs_input" => :needs_input_mailed_at }.freeze

  # The owner opened the report after it ended (ReportsController#show), so its outcome mail can skip it. A column
  # write: no callbacks, no broadcast, and updated_at stays the run's.
  def mark_viewed!
    update_column(:viewed_at, Time.current) if MAILED_OUTCOMES.key?(status) && !viewed_since_finish?
  end

  def viewed_since_finish? = viewed_at.present? && finished_at.present? && viewed_at >= finished_at

  # Whether the outcome mail (ReportMailJob) should go: a full report that ended done or needs_input while its owner
  # was away. Never for a Snapshot (it takes seconds, so they are on the page), a sample or an account with no address.
  def outcome_mail_due?
    owner = show.user
    agent? && MAILED_OUTCOMES.key?(status) && !viewed_since_finish? && owner.email.present? && !owner.samples_owner?
  end

  # Takes this outcome's mail for the caller: the claim's time for the first claim and nil for any other, so an
  # at-least-once job sends it once.
  def claim_outcome_mail!
    column = MAILED_OUTCOMES.fetch(status)
    claimed_at = Time.current
    claimed_at if self.class.where(id: id, column => nil).update_all(column => claimed_at) == 1
  end

  # Gives back the claim taken at claimed_at when its mail wasn't delivered (R119), so the job's retry can send it.
  # Only that claim: while it holds, no other run could take the mail.
  def release_outcome_mail!(claimed_at)
    column = MAILED_OUTCOMES.fetch(status)
    self.class.where(id: id, column => claimed_at).update_all(column => nil)
  end

  # Saves one section and pushes it to open report pages. Matches live in their own table, so
  # save_section!(:matches, nil) just re-renders the list.
  def save_section!(name, data = nil)
    name = name.to_s
    raise ArgumentError, "unknown section #{name}" unless SECTIONS.include?(name)

    update!(SECTION_COLUMNS.fetch(name) => data) if SECTION_COLUMNS.key?(name)
    sponsor_matches.reset if name == "matches" # the partial reads the association; drop any stale copy
    broadcast_replace_to self, target: "report_#{name}", partial: "reports/sections/#{name}",
                                locals: { report: self, read_only: false }
  end

  private

  # Open report pages re-render (morphed) so the badge, Re-run button and failed/needs_input cards follow.
  def broadcast_status_refresh
    broadcast_refresh_to(self)
  end
end
