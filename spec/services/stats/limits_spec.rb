require "rails_helper"

RSpec.describe Stats::Limits do
  it "has polite defaults: 30 s between runs plus up to 15 s, 40 an hour, 300 a day" do
    expect(described_class.current).to have_attributes(min_gap: 30, jitter: 15, per_hour: 40, per_day: 300)
  end

  it "reads stored settings, and ignores one that isn't allowed" do
    AppSettings.set(:stats_min_gap_seconds, 60)
    AppSettings.set(:stats_runs_per_day, "lots")
    AppSettings.set(:stats_runs_per_hour, 0)
    expect(described_class.current).to have_attributes(min_gap: 60, per_day: 300, per_hour: 40)
  end

  it "saves what changed and says so" do
    limits = described_class.new(stats_min_gap_seconds: "45", stats_gap_jitter_seconds: "15", stats_runs_per_hour: "20",
                                 stats_runs_per_day: "300")
    expect(limits.save).to be(true)
    expect(limits.changed_settings).to contain_exactly("stats_min_gap_seconds from 30 to 45", "stats_runs_per_hour from 40 to 20")
    expect(described_class.current).to have_attributes(min_gap: 45, per_hour: 20)
  end

  it "refuses values that would make the client less polite, or that don't add up" do
    limits = described_class.new(stats_min_gap_seconds: "2", stats_gap_jitter_seconds: "-1", stats_runs_per_hour: "500",
                                 stats_runs_per_day: "100")
    expect(limits.save).to be(false)
    expect(limits.errors.full_messages).to include(
      "Seconds between runs must be a whole number from 10 to 3600.",
      "Most random extra seconds must be a whole number from 0 to 3600.",
      "Runs an hour can't be more than the runs a day."
    )
    expect(Setting.where(key: described_class::DEFAULTS.keys.map(&:to_s))).to be_empty
  end
end
