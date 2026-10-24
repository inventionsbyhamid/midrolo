FactoryBot.define do
  factory :sponsor_match do
    report
    show { report.show }
    sequence(:brand_entity_id) { |n| "brand-#{n}" }
    sequence(:name) { |n| "Brand #{n}" }
    sequence(:position)
    category { "Finance" }
    affinity { 0.72 }
    popularity { 0.4 }
    fit_score { 80 }
    tier { "easy_yes" }
    reason { "Your audience shares 3 taste signals with these fans." }
    evidence { { "shared_tags" => [ "Personal Finance", "Investing", "Side Projects" ], "proven" => { "items" => [], "count" => 0 } } }
  end
end
