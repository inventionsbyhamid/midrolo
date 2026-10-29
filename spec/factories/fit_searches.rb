FactoryBot.define do
  factory :fit_search do
    user
    brand
    query { "Running shoes for trail runners" }
    status { "queued" }
  end

  factory :fit_result do
    fit_search
    podcast
    sequence(:position)
    score { 80 }
  end

  factory :saved_podcast do
    brand
    podcast
    user
  end

  factory :removal_request do
    podcast
    email { "owner@example.com" }
    reason { "I host this show and want the page down." }
  end

  factory :suppression do
    kind { "podcast" }
    sequence(:value) { |n| "podcast-guid-#{n}" }
  end
end
