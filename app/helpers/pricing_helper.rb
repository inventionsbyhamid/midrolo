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

  def plan_tagline(plan)
    case plan
    when :creator then "For a show chasing its next sponsors."
    when :pro then "For hosts with up to #{pluralize(Entitlements.limits(:pro)[:shows], 'show')}."
    when :sprint then "For a focused push, like the weeks before a new season."
    end
  end

  # What the page says about buying, by Billing.mode: on the waitlist, that paid plans aren't open yet. Test mode has
  # its own note under the buttons (test_payments_note); live mode needs none.
  def pricing_mode_note
    "Paid plans open soon. Join the founding-member waitlist and we'll email you when they do." if Billing.mode == :waitlist
  end

  # What the plan includes, a line each.
  def plan_features(plan)
    limits = Entitlements.limits(plan)
    case plan
    when :free then free_features(limits)
    when :creator then creator_features(limits)
    when :pro then pro_features(limits)
    when :sprint then [ "Everything in #{Entitlements.limits(:pro)[:name]} for #{limits[:duration_days]} days",
                        "One payment, no renewal" ]
    end
  end

  private

  def free_features(limits)
    [ pluralize(limits[:shows], "show"),
      "#{pluralize(limits[:snapshots_per_month], 'Snapshot')} a month: taste profile, map and your top #{limits[:visible_matches]} brand matches",
      "A media kit page#{" with a small “Made with #{APP_NAME}” badge" if limits[:kit_badge]}",
      "Every sample report" ]
  end

  def creator_features(limits)
    [ pluralize(limits[:shows], "show"),
      "#{pluralize(limits[:agent_reports], 'full agent report')} a month",
      "Every match, with its reason, evidence and proven sponsors",
      "#{pluralize(limits[:pitches], 'pitch pack')} a month",
      ("A media kit without the badge" unless limits[:kit_badge]),
      ("A pipeline to track every brand you pitch" if limits[:pipeline]) ].compact
  end

  def pro_features(limits)
    creator_scan = Entitlements.limits(:creator)[:deep_scan_similar]
    [ pluralize(limits[:shows], "show"),
      "#{pluralize(limits[:agent_reports], 'full agent report')} and #{pluralize(limits[:pitches], 'pitch pack')} a month",
      "A deeper sponsor scan: #{limits[:deep_scan_similar]} similar shows checked, not #{creator_scan}",
      ("CSV export of your pipeline" if limits[:csv_export]),
      "Everything in #{Entitlements.limits(:creator)[:name]}" ].compact
  end
end
