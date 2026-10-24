FactoryBot.define do
  factory :report do
    show
    kind { "snapshot" }
    status { "queued" }
  end

  factory :agent_step do
    report
    sequence(:position)
    tool { "read_feed" }
    label { "Reading your last 15 episodes…" }
    status { "running" }
  end
end
