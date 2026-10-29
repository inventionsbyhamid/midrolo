FactoryBot.define do
  factory :brand do
    sequence(:name) { |n| "Brand #{n}" }
    sequence(:domain) { |n| "brand-#{n}.example" }
  end

  factory :sponsor_mention do
    episode
    podcast { episode.podcast }
    brand
    detected_by { "pattern" }
    published_at { episode.published_at }
    evidence { "This episode is brought to you by our sponsor." }
  end

  factory :brand_member do
    brand
    user
    role { "owner" }
  end

  factory :block do
    podcast
    brand
  end
end
