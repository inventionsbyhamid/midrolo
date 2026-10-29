FactoryBot.define do
  factory :media_kit do
    show
    headline { "Plain-English money lessons for first-time founders" }
    about { "Every week we sit down with a founder who just made their first big money decision." }

    trait :published do
      after(:build) { |kit| kit.show.verify!(via: "admin") }
      published_at { Time.current }
    end
  end
end
