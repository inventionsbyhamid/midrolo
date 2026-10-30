# Billing copy: prices as the plan buttons show them (billing/_plan_button), the test-payments note (R66), whether the
# user is on a price's waitlist, and the account page's line on when a plan renews or ends.
module BillingHelper
  INTERVALS = { monthly: "/month", yearly: "/year", once: " once" }.freeze
  TEST_NOTE = "Test mode: pay with the test card 4242 4242 4242 4242 and any future date. Nothing is charged.".freeze

  # "$19/month", "$190/year", "$49 once"
  def price_label(price) = "$#{price.usd}#{INTERVALS.fetch(price.interval)}"

  def price_plan_name(price) = Entitlements.limits(price.plan.to_sym).fetch(:name)

  # The note under checkout buttons that take test payments: in test mode, and a judge's or admin's test checkout on
  # the waitlist. nil otherwise.
  def test_payments_note
    return unless Billing.mode == :test || Billing.test_checkout?(current_user)

    tag.p(TEST_NOTE, class: "text-sm text-ink-soft")
  end

  # Whether the signed-in user's email is on price_key's waitlist already (billing/_plan_button), so the button says
  # so instead of asking again. One query a page.
  def on_waitlist?(price_key)
    return false unless user_signed_in?

    @waitlisted_price_keys ||= WaitlistEntry.where(email: current_user.email).pluck(:price_key)
    @waitlisted_price_keys.include?(price_key.to_s)
  end

  # "Renews on Nov 24, 2026." and the like, or nil without a period end.
  def renewal_line(subscription)
    return unless subscription&.current_period_end

    date = subscription.current_period_end.strftime("%b %-d, %Y")
    if subscription.sprint? then "Your Sprint ends on #{date}."
    elsif subscription.past_due? then "Your last payment failed. Update your card in Manage billing to keep your plan."
    elsif subscription.canceled? || subscription.cancel_at_period_end? then "Ends on #{date}. It won't renew."
    else "Renews on #{date}."
    end
  end
end
