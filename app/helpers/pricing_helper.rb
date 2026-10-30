# The pricing table's copy (pages/_plans): each plan's prices and what it includes, all read from config/plans.yml
# through Entitlements and Billing, so the page can't drift from what the plans allow.
module PricingHelper
  PAID_PLANS = %i[creator pro].freeze

  # The plan's price for an interval (:monthly, :yearly, :once), or nil when it isn't sold that way.
  def plan_price(plan, interval) = Billing.prices.find { |price| price.plan == plan.to_s && price.interval == interval }

  # "2 months free" for a yearly price, against twelve of the monthly one.
  def yearly_saving(plan)
    monthly = plan_price(plan, :monthly)&.usd.to_i
    yearly = plan_price(plan, :yearly)&.usd.to_i
    return if monthly.zero? || yearly.zero?

    months = ((monthly * 12 - yearly) / monthly.to_f).round
    "#{pluralize(months, 'month')} free" if months.positive?
  end

  def free_price_label = "$#{Entitlements.plans.dig(:free, :price_monthly_usd).to_i}"

  # What the page says about buying, by Billing.mode: on the waitlist, that paid plans aren't open yet and what joining
  # does. Test mode has its own note under the buttons (test_payments_note); live mode needs none.
  def pricing_mode_note
    PlansHelper::WAITLIST_DETAIL if Billing.mode == :waitlist
  end

  # Whether a plan on sale allows more shows than plan does, so "Upgrade" adds shows (shows/new at the limit).
  def more_shows_on_sale?(plan)
    Billing.prices.any? { |price| Entitlements.limits(price.plan.to_sym)[:shows] > plan.max_shows }
  end

  # What the plan includes: five short lines at most (R97), so the cards stay skimmable.
  def plan_features(plan)
    limits = Entitlements.limits(plan)
    case plan
    when :free then free_features(limits)
    when :creator then creator_features(limits)
    when :pro then pro_features(limits)
    when :sprint then [ "#{limits[:duration_days]} days of #{Entitlements.limits(:pro)[:name]}", "One payment, no renewal",
                        "Good for a new season's launch" ]
    end
  end

  private

  def free_features(limits)
    [ pluralize(limits[:shows], "show"),
      "#{pluralize(limits[:snapshots_per_month], 'Snapshot')} a month",
      "Your top #{limits[:visible_matches]} brand matches",
      "Media kit#{' with a small badge' if limits[:kit_badge]}",
      "Every sample report" ]
  end

  def creator_features(limits)
    [ pluralize(limits[:shows], "show"),
      monthly_work(limits),
      "Every match, with its evidence",
      ("A pipeline for your pitches" if limits[:pipeline]),
      ("Media kit without the badge" unless limits[:kit_badge]) ].compact
  end

  def pro_features(limits)
    creator_scan = Entitlements.limits(:creator)[:deep_scan_similar]
    [ pluralize(limits[:shows], "show"),
      monthly_work(limits),
      "Deeper scan: #{limits[:deep_scan_similar]} similar shows, not #{creator_scan}",
      ("CSV export of your pipeline" if limits[:csv_export]),
      "Everything in #{Entitlements.limits(:creator)[:name]}" ].compact
  end

  # "4 full reports and 40 pitch packs a month"
  def monthly_work(limits)
    "#{pluralize(limits[:agent_reports], 'full report')} and #{pluralize(limits[:pitches], 'pitch pack')} a month"
  end
end
