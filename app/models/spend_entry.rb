# One row per billable call (LLM or taste), attributed to a budget bucket.
class SpendEntry < ApplicationRecord
  KINDS = %w[llm taste].freeze
  # catalog: the marketplace's own LLM work (sponsor detection), under its own daily cap (Llm::Budget).
  BUCKETS = %w[dev promo judge paid sample catalog].freeze

  belongs_to :user, optional: true
  belongs_to :fit_search, optional: true

  enum :kind, KINDS.index_with(&:itself), validate: true
  enum :bucket, BUCKETS.index_with(&:itself), validate: true, prefix: true

  scope :today, -> { where(created_at: Time.current.all_day) }
end
