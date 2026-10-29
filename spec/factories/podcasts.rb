FactoryBot.define do
  factory :podcast do
    sequence(:title) { |n| "Show #{n}" }
    author { "Host Person" }
    sequence(:feed_url) { |n| "https://example.com/feed-#{n}.xml" }
    categories { [ "Business" ] }
    source { "search" }

    trait :active do
      status { "active" }
      episode_count { 12 }
      last_published_at { 3.days.ago }
    end

    trait :indexable do
      active
      indexable { true }
    end

    trait :claimed do
      claimed_at { Time.current }
    end

    trait :with_artwork do
      artwork_url { "https://img.example.com/art.jpg" }
      artwork_image { association :image, :with_file }
    end
  end

  factory :podcast_redirect do
    podcast
    sequence(:from_slug) { |n| "old-slug-#{n}" }
  end

  factory :image do
    sequence(:sha256) { |n| Digest::SHA256.hexdigest("image-#{n}") }
    source_url { "https://img.example.com/art.jpg" }
    content_type { "image/png" }

    trait :with_file do
      after(:build) do |image|
        image.file.attach(io: Rails.root.join("spec/fixtures/files/cover.png").open, filename: "cover.png",
                          content_type: "image/png")
      end
    end
  end

  factory :episode do
    podcast
    sequence(:guid) { |n| "episode-guid-#{n}" }
    sequence(:title) { |n| "Episode #{n}" }
    published_at { 1.week.ago }
  end

  factory :podcast_person do
    podcast
    sequence(:name) { |n| "Person #{n}" }
    role { "host" }
  end
end
