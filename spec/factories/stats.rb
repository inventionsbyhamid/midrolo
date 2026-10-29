FactoryBot.define do
  factory :stat_reading do
    podcast
    metric { StatReading::DOWNLOADS_PER_EPISODE }
    value { 1200 }
    source { "provided" }
    trust { "provided" }
    period_days { 30 }
    captured_at { Time.current }
    expires_at { StatReading::TTL.from_now }
  end

  factory :stat_connection do
    podcast
    provider { "spotify" }
    sequence(:external_id) { |n| "spotify-show-#{n}" }
    status { "pending_invite" }
  end

  factory :service_session do
    platform { "spotify" }
    credentials { { "sp_dc" => "fake-cookie" }.to_json }
    status { "ok" }
  end
end
