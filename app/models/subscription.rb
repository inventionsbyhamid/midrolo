# A paid plan from a billing provider (spec §10, R60). Task 17 writes these from checkout and webhooks; Entitlements
# reads them. A Sponsor Sprint is a one-off payment, stored as plan "sprint" with a 30-day period; it grants Pro.
class Subscription < ApplicationRecord
  PLANS = %w[creator pro sprint].freeze
  STATUSES = %w[active past_due canceled].freeze
  # Statuses that keep the plan through the period (and the renewal grace).
  RENEWING = %w[active past_due].freeze
  # The best plan wins when several entitle: pro and sprint (Pro for 30 days) over creator.
  PLAN_RANK = { "creator" => 1, "pro" => 2, "sprint" => 2 }.freeze
  # Renewal webhooks can arrive late, so a renewing subscription keeps its plan this long past its period end.
  RENEWAL_GRACE = 3.days

  belongs_to :user

  enum :plan, PLANS.index_with(&:itself), validate: true
  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :provider, presence: true

  # Subscriptions that give their plan now: active or past due within the period plus RENEWAL_GRACE (or with no
  # period end yet), or canceled with time left in the period. A sprint never renews: it ends with its period.
  scope :entitling, lambda {
    period_end = arel_table[:current_period_end]
    in_period = period_end.gt(Time.current)
    where(status: RENEWING).where.not(plan: "sprint").where(period_end.eq(nil).or(period_end.gt(RENEWAL_GRACE.ago)))
      .or(where(status: RENEWING, plan: "sprint").where(in_period))
      .or(where(status: "canceled").where(in_period))
  }

  # The user's entitling subscription with the best plan (the newest of equals), or nil. plans narrows the plans looked at.
  def self.best_for(user, plans: PLANS)
    user.subscriptions.entitling.where(plan: plans)
        .max_by { |subscription| [ PLAN_RANK.fetch(subscription.plan), subscription.id ] }
  end
end
