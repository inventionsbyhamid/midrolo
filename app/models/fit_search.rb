# A brand's search for podcasts that fit it (FitSearchJob): the agent's steps log through Research::StepLogger as a
# report's do, with the same trace UI, and its results are FitResults.
class FitSearch < ApplicationRecord
  include HasPublicId

  STATUSES = %w[queued running done failed].freeze
  ACTIVE = %w[queued running].freeze
  QUERY_LIMIT = 200
  # A search that hasn't finished in this long is presumed dead (a killed worker, a lost job), as a report is
  # (Report::STALE_AFTER).
  STALE_AFTER = 15.minutes
  STALE_MESSAGE = "This search stopped before it finished. Run it again.".freeze

  belongs_to :user
  belongs_to :brand, optional: true
  has_many :agent_steps, -> { order(:position, :id) }, as: :run, dependent: :delete_all, inverse_of: :run
  has_many :results, -> { order(:position, :id) }, class_name: "FitResult", dependent: :delete_all,
                                                    inverse_of: :fit_search
  has_many :spend_entries, dependent: :nullify

  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :query, presence: true, length: { maximum: QUERY_LIMIT }
  validates :budget_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  scope :active, -> { where(status: ACTIVE) }
  scope :stale, lambda {
    cutoff = STALE_AFTER.ago
    where(status: "running").where(started_at: ...cutoff).or(where(status: "queued").where(created_at: ...cutoff))
  }

  # Fails each stale search in searches (records already loaded), so a page that lists or shows them says so.
  def self.fail_stale(searches) = searches.each { |search| search.fail_if_stale! }

  def active? = status.in?(ACTIVE)

  def stale?(now = Time.current)
    cutoff = now - STALE_AFTER
    (running? && started_at.present? && started_at < cutoff) || (queued? && created_at < cutoff)
  end

  # A stale search becomes failed with STALE_MESSAGE, once (a guarded update, so a job finishing at the same moment
  # wins), and its open pages refresh. True when this call failed it.
  def fail_if_stale!
    return false unless stale?

    now = Time.current
    failed = self.class.stale.where(id: id).update_all(status: "failed", finished_at: now, error_message: STALE_MESSAGE,
                                                       updated_at: now)
    return false unless failed == 1

    reload
    FitSearch::Broadcast.refresh(self)
    true
  end

  # What the search was asked, as FitSearch::Start takes it, so a failed search can run again as it was.
  def rerun_params
    { query: query, website: website, categories: categories, budget: (budget_cents / 100 if budget_cents) }.compact
  end

  def categories=(value)
    super(Array(value).map { |category| category.to_s.strip }.compact_blank.uniq)
  end
end
