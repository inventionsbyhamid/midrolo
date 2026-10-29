# Plan copy: the upgrade prompt (shared/_upgrade_prompt), which says why Entitlements refused and what to do next
# (R63, R63a), and the plan and usage lines on the account page. Both count done work, and name work in progress
# apart from it, so they never contradict each other.
module PlansHelper
  UpgradePrompt = Data.define(:message, :detail, :action)

  REASONS = %i[limit budget paused plan busy].freeze
  # Each kind's noun in a sentence, and its label on the account page.
  KINDS = { agent: { noun: "report", label: "Full reports" },
            snapshot: { noun: "Snapshot", label: "Snapshots" },
            pitch: { noun: "pitch", label: "Pitches" } }.freeze
  PAUSED_MESSAGE = "New reports are paused for a little while. Please try again later.".freeze
  PITCH_PACK = "Each one is an email ready to send, three ad read angles, an offer priced from your rate card and " \
               "a follow up email.".freeze

  # The copy for a refusal's details (Entitlements::NotAllowed#details): reason, kind and bucket, and for :limit the
  # used, in_flight and limit counts and the period (nil when the plan counts in total).
  def upgrade_prompt_copy(prompt)
    kind = prompt.fetch(:kind)
    work = kind == :pitch ? "pitch packs" : "full reports"
    case prompt.fetch(:reason)
    when :limit
      UpgradePrompt.new(limit_message(prompt), nil, "See plans")
    when :budget
      if prompt[:bucket].in?(%i[paid judge])
        UpgradePrompt.new("We've hit today's limit for #{work}. Try again tomorrow. This didn't use any of your quota.",
                          nil, nil)
      else
        UpgradePrompt.new("#{work.upcase_first} are paused for now. Join the waitlist.", nil, "Join the waitlist")
      end
    when :paused
      UpgradePrompt.new(AppSettings.get(:runs_paused_reason).to_s.presence || PAUSED_MESSAGE, nil, nil)
    when :busy
      UpgradePrompt.new(Research::Run.busy_message(kind), nil, nil)
    else
      kind == :pitch ? UpgradePrompt.new("Pitch packs are on Creator and up", PITCH_PACK, "See plans")
                     : UpgradePrompt.new("Full agent reports are on Creator and up", nil, "See plans")
    end
  end

  # The refusal a redirect carried in flash[:upgrade] (ApplicationController#redirect_with_upgrade_prompt), back in the
  # shape NotAllowed#details gives, or nil when it's missing or malformed.
  def flashed_upgrade
    upgrade = flash[:upgrade]
    return unless upgrade.is_a?(Hash)

    reason, kind = upgrade.values_at("reason", "kind").map { |value| value.to_s.to_sym }
    return unless REASONS.include?(reason) && KINDS.key?(kind)

    counts = upgrade.values_at("used", "in_flight", "limit")
    return if reason == :limit && !counts.all?(Integer)

    { reason: reason, kind: kind, bucket: upgrade["bucket"].presence&.to_sym, used: counts[0], in_flight: counts[1],
      limit: counts[2], period: upgrade["period"].presence }
  end

  # The account page's line about the plan.
  def plan_summary(plan)
    case plan.key
    when :judge then "Judge access is on: Pro features with #{pluralize(plan.limit(:agent), 'full report')} and unlimited pitches."
    when :promo then "#{promo_offer}: #{promo_allowance}."
    when :sprint then "You're on the #{plan.name} plan: Pro features for #{plan.duration_days} days."
    else "You're on the #{plan.name} plan."
    end
  end

  # "Full reports: 1 of 4 used this billing period, 1 in progress", "Unlimited pitches", "Pitches: not on the Free plan".
  def usage_line(plan, kind)
    label = KINDS.fetch(kind).fetch(:label)
    limit = plan.limit(kind)
    return "Unlimited pitches" if kind == :pitch && limit.infinite?
    return "#{label}: not on the #{plan.name} plan" unless limit.positive?

    in_flight = plan.in_flight(kind)
    period = plan.counted_in_total?(kind) ? nil : plan.period_name
    "#{label}: #{plan.used(kind)} of #{limit} used#{" this #{period}" if period}#{", #{in_flight} in progress" if in_flight.positive?}"
  end

  # "Free Pro trial for the Qloo hackathon judging, through Nov 6"
  def promo_offer
    "Free Pro trial for the Qloo hackathon judging, through #{Entitlements.promo_until&.strftime('%b %-d')}"
  end

  # "up to 3 shows, each with a Snapshot and a full report", from plans.yml (R151).
  def promo_allowance
    shows = Entitlements.limits(:promo)[:shows]
    "up to #{pluralize(shows, 'show')}, each with a Snapshot and a full report"
  end

  private

  # "You've used 3 of 4 reports this billing period, and 1 more is in progress": the noun follows the limit.
  def limit_message(prompt)
    used, in_flight, limit, period = prompt.values_at(:used, :in_flight, :limit, :period)
    noun = KINDS.fetch(prompt.fetch(:kind)).fetch(:noun).pluralize(limit)
    message = "You've used #{used} of #{limit} #{noun}"
    message += " this #{period}" if period
    message += ", and #{in_flight} more #{in_flight == 1 ? 'is' : 'are'} in progress" if in_flight.to_i.positive?
    message
  end
end
