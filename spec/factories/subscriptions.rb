FactoryBot.define do
  # A paid plan as a billing provider reports it (Task 17 writes these from webhooks). Sprint is a one-off payment:
  # a row with plan "sprint" and a 30-day period.
  factory :subscription do
    user
    provider { "dodo" }
    sequence(:provider_customer_id) { |n| "cus_#{n}" }
    sequence(:provider_subscription_id) { |n| "sub_#{n}" }
    plan { "creator" }
    price_key { plan == "sprint" ? "sprint" : "#{plan}_monthly" }
    status { "active" }
    current_period_start { 10.days.ago }
    current_period_end { 20.days.from_now }
    cancel_at_period_end { false }
  end
end
