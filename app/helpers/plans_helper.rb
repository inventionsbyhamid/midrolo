# Plan copy: the upgrade prompt (shared/_upgrade_prompt), which says why Entitlements refused and what to do next
# (R63, R63a), and the plan line and usage bars on the account page. Both count done work, and name work in progress
# apart from it, so they never contradict each other.
module PlansHelper
  UpgradePrompt = Data.define(:message, :detail, :action)
  # One kind's usage on the account page (accounts/_plan): done and in-flight work against the limit, and the period
  # they count in (nil when the plan counts in total). limit is Float::INFINITY when unlimited, 0 when the plan
  # doesn't include the kind; neither counts anything.
  Usage = Data.define(:kind, :label, :plan_name, :used, :in_flight, :limit, :period) do
    def included? = limit.positive?
    def unlimited? = limit == Float::INFINITY
    def metered? = included? && !unlimited?
  end

  REASONS = %i[limit budget paused plan busy].freeze
  # Each kind's noun in a sentence, and its label on the account page.
  KINDS = { agent: { noun: "report", label: "Full reports" },
            snapshot: { noun: "Snapshot", label: "Snapshots" },
            pitch: { noun: "pitch", label: "Pitches" } }.freeze
  # The most segments a usage bar has: a smaller limit gets one segment per report, Snapshot or pitch.
  USAGE_SEGMENTS = 20
  PAUSED_MESSAGE = "New reports are paused for a little while. Please try again later.".freeze
  SNAPSHOT_ACTION = "Get my free Snapshot".freeze
  PITCH_PACK = "Each one is an email ready to send, three ad read angles, an offer priced from your rate card and " \
               "a follow up email.".freeze
  # While paid plans only take waitlist sign ups, a prompt that points at /pricing says so before the click.
  WAITLIST_DETAIL = "Paid plans aren't on sale yet. Join the waitlist and we'll email you when they open.".freeze
  WAITLIST_ACTION = "Join the waitlist".freeze

  # The copy for a refusal's details (Entitlements::NotAllowed#details): reason, kind and bucket, and for :limit the
  # used, in_flight and limit counts and the period (nil when the plan counts in total).
  def upgrade_prompt_copy(prompt)
    kind = prompt.fetch(:kind)
    work = kind == :pitch ? "pitch packs" : "full reports"
    case prompt.fetch(:reason)
    when :limit
      UpgradePrompt.new(limit_message(prompt), *plans_next_step(prompt))
    when :budget
      if prompt[:bucket].in?(%i[paid judge])
        UpgradePrompt.new("We've hit today's limit for #{work}. Try again tomorrow. This didn't use any of your quota.",
                          nil, nil)
      else
        UpgradePrompt.new("#{work.upcase_first} are paused for now.", *plans_next_step(prompt))
      end
    when :paused
      UpgradePrompt.new(AppSettings.get(:runs_paused_reason).to_s.presence || PAUSED_MESSAGE, nil, nil)
    when :busy
      UpgradePrompt.new(Research::Run.busy_message(kind), nil, nil)
    else
      if kind == :pitch
        UpgradePrompt.new("Pitch packs are on Creator and up", PITCH_PACK, "See plans")
      elsif plans_on_waitlist?
        # Nothing can be bought yet (review PO-12): no dead end at the pricing page, the free Snapshot instead.
        UpgradePrompt.new("Full reports open with paid plans soon", nil, SNAPSHOT_ACTION)
      else
        UpgradePrompt.new("Full agent reports are on Creator and up", nil, "See plans")
      end
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

  # The detail and action of a prompt that sends the user to /pricing: the waitlist while that's all it offers, except
  # to a subscriber (the :paid bucket), who has a plan already.
  def plans_next_step(prompt)
    prompt[:bucket] != :paid && plans_on_waitlist? ? [ WAITLIST_DETAIL, WAITLIST_ACTION ] : [ nil, "See plans" ]
  end

  # True while paid plans only take waitlist sign ups for this user (Billing.mode :waitlist, no test checkout).
  def plans_on_waitlist?
    return false unless Billing.mode == :waitlist

    viewer = current_user if request&.env&.key?("warden") # a page rendered outside a request has no viewer
    !Billing.checkout_open?(viewer)
  end

  # The account page's line about the plan.
  def plan_summary(plan)
    case plan.key
    when :judge then "Judge access is on: Pro features with #{pluralize(plan.limit(:agent), 'full report')} and unlimited pitches."
    when :promo then "#{promo_offer}: #{promo_allowance}. After that, you're on the #{Entitlements.limits(:free)[:name]} plan."
    when :sprint then "You're on the #{plan.name} plan: Pro features for #{plan.duration_days} days."
    else "You're on the #{plan.name} plan."
    end
  end

  # The plan's usage of one kind, counted only when the plan has a limit for it.
  def plan_usage(plan, kind)
    limit = plan.limit(kind)
    metered = limit.positive? && limit.finite?
    Usage.new(kind: kind, label: KINDS.fetch(kind).fetch(:label), plan_name: plan.name, limit: limit,
              used: metered ? plan.used(kind) : 0, in_flight: metered ? plan.in_flight(kind) : 0,
              period: (plan.period_name unless plan.counted_in_total?(kind)))
  end

  # "<strong>1 of 4</strong> used this billing period, 1 in progress", "<strong>Unlimited</strong>", "Not on the Free
  # plan": a usage bar's words, the numbers bold.
  def usage_count(usage)
    return tag.strong("Unlimited") if usage.unlimited?
    return "Not on the #{usage.plan_name} plan" unless usage.included?

    safe_join([ tag.strong("#{usage.used} of #{usage.limit}"), " used", (" this #{usage.period}" if usage.period),
                (", #{usage.in_flight} in progress" if usage.in_flight.positive?) ].compact)
  end

  # A usage bar's segments in order: :on for done work, :busy for work in progress, :off for what's left. One segment
  # per unit up to USAGE_SEGMENTS; past that the bar scales, and any work lights at least one segment.
  def usage_segments(usage)
    count = [ usage.limit, USAGE_SEGMENTS ].min
    on = usage_lit(usage.used, usage.limit, count)
    busy = usage_lit(usage.used + usage.in_flight, usage.limit, count) - on
    Array.new(count) { |index| index < on ? :on : (index < on + busy ? :busy : :off) }
  end

  # "Free Pro through Nov 6": what every account gets while the promo runs, in words a user (not a judge) reads.
  def promo_offer
    "Free #{Entitlements.limits(:pro)[:name]} through #{Entitlements.promo_until&.strftime('%b %-d')}"
  end

  # "up to 3 shows, each with a Snapshot and a full report", from plans.yml (R151).
  def promo_allowance
    shows = Entitlements.limits(:promo)[:shows]
    "up to #{pluralize(shows, 'show')}, each with a Snapshot and a full report"
  end

  private

  # How many of count segments value of limit lights: exact when each unit has its own segment; scaled otherwise, but
  # never none for some work or all of them short of the limit.
  def usage_lit(value, limit, count)
    return value.clamp(0, count) if limit <= count

    lit = (value * count / limit.to_f).round.clamp(0, count)
    return 1 if value.positive? && lit.zero?
    return count - 1 if value < limit && lit == count

    lit
  end

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
