FactoryBot.define do
  factory :show do
    user
    sequence(:title) { |n| "Show #{n}" }
    author { "Host Person" }
    sequence(:feed_url) { |n| "https://example.com/feed-#{n}.xml" }
    categories { [ "Business" ] }
  end
end
