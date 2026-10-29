FactoryBot.define do
  factory :conversation do
    podcast
    brand
    association :started_by, factory: :user
    status { "open" }
    format { "midroll" }
    months { [ "2026-11" ] }
    budget_cents { 50_000 }
  end

  factory :message do
    conversation
    user
    body { "Hi, we'd love a midroll in November." }
  end
end
