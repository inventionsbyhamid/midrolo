FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    name { "Test User" }
    provider { "google_oauth2" }
    sequence(:uid) { |n| "uid-#{n}" }

    # On a paid plan through an active subscription: create(:user, :subscribed) is Creator, plan: "pro" for Pro.
    trait :subscribed do
      transient { plan { "creator" } }

      after(:create) { |user, context| create(:subscription, user: user, plan: context.plan) }
    end
  end
end
