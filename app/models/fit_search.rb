# A brand's search for podcasts that fit it (FitSearchJob): the agent's steps log through Research::StepLogger as a
# report's do, with the same trace UI, and its results are FitResults.
class FitSearch < ApplicationRecord
  include HasPublicId

  STATUSES = %w[queued running done failed].freeze
  ACTIVE = %w[queued running].freeze
  QUERY_LIMIT = 200

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

  def active? = status.in?(ACTIVE)

  def categories=(value)
    super(Array(value).map { |category| category.to_s.strip }.compact_blank.uniq)
  end
end
