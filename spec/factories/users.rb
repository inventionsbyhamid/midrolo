FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    name { "Test User" }
    provider { "google_oauth2" }
    sequence(:uid) { |n| "uid-#{n}" }
  end
end
