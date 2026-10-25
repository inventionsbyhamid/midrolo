# Plan copy: the upgrade prompt (shared/_upgrade_prompt), which says why Entitlements refused and what to do next
# (R63), and the plan and usage lines on the account page.
module PlansHelper
  UpgradePrompt = Data.define(:message, :detail, :action)

  REASONS = %i[limit budget paused plan].freeze
  NOUNS = { agent: "reports", snapshot: "Snapshots", pitch: "pitches" }.freeze
  PAUSED_MESSAGE = "New reports are paused for a little while. Please try again later.".freeze
  PITCH_PACK = "Each one is a ready-to-send email, three ad-read angles, an offer priced from your rate card and " \
               "a follow-up.".freeze

  # The prompt for a refusal (Entitlements::NotAllowed#reason) of a kind (:agent, :snapshot or :pitch) on a plan.
  def upgrade_prompt(reason, kind, plan)
    kind = kind.to_sym
    case reason.to_sym
    when :limit
      UpgradePrompt.new("You've used #{plan.in_use(kind)} of #{plan.limit(kind)} #{NOUNS.fetch(kind)}#{period_phrase(plan, kind)}",
                        nil, "See plans")
    when :budget
      UpgradePrompt.new("#{kind == :pitch ? 'Pitch packs' : 'Full reports'} are paused for now — join the waitlist",
                        nil, "Join the waitlist")
    when :paused
      UpgradePrompt.new(AppSettings.get(:runs_paused_reason).to_s.presence || PAUSED_MESSAGE, nil, nil)
    else
      kind == :pitch ? UpgradePrompt.new("Pitch packs are on Creator and up", PITCH_PACK, "See plans")
                     : UpgradePrompt.new("Full agent reports are on Creator and up", nil, "See plans")
    end
  end

  # The [reason, kind] a redirect carried in flash[:upgrade] (ApplicationController#redirect_with_upgrade_prompt),
  # or nil.
  def flashed_upgrade
    upgrade = flash[:upgrade]
    return unless upgrade.is_a?(Hash)

    reason, kind = upgrade.values_at("reason", "kind").map { |value| value.to_s.to_sym }
    [ reason, kind ] if REASONS.include?(reason) && NOUNS.key?(kind)
  end

  # The account page's line about the plan.
  def plan_summary(plan)
    case plan.key
    when :judge then "Judge access is on: Pro features with #{pluralize(plan.limit(:agent), 'full report')} and unlimited pitches."
    when :promo then "#{promo_offer}, with #{pluralize(plan.limit(:agent), 'full report')}."
    when :sprint then "You're on the Sponsor Sprint: Pro features for 30 days."
    else "You're on the #{plan.name} plan."
    end
  end

  # "Full reports: 1 of 4 used this billing period", "Unlimited pitches", "Pitches: not on the Free plan".
  def usage_line(plan, kind)
    label = { agent: "Full reports", snapshot: "Snapshots", pitch: "Pitches" }.fetch(kind)
    limit = plan.limit(kind)
    return "Unlimited pitches" if kind == :pitch && limit.infinite?
    return "#{label}: not on the #{plan.name} plan" unless limit.positive?

    "#{label}: #{plan.used(kind)} of #{limit} used#{period_phrase(plan, kind)}"
  end

  # "Free Pro access during the Qloo hackathon judging — through Nov 6"
  def promo_offer
    "Free Pro access during the Qloo hackathon judging — through #{Entitlements.promo_until&.strftime('%b %-d')}"
  end

  private

  def period_phrase(plan, kind) = plan.counted_in_total?(kind) ? "" : " this #{plan.period_name}"
end
