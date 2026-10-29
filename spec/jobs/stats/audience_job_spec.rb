require "rails_helper"

RSpec.describe Stats::AudienceJob do
  include ActiveJob::TestHelper

  let(:owner) { create(:user) }
  let(:podcast) { create(:podcast, title: "The Founder's Ledger", claimed_at: 1.day.ago) }
  let!(:owner_show) { create(:show, user: owner, podcast: podcast, verified_at: 1.day.ago) }
  let!(:session) { create(:service_session, platform: "spotify") }
  let(:connection) do
    create(:stat_connection, podcast: podcast, show: owner_show, user: owner, provider: "spotify", status: "active",
                             activated_at: 2.days.ago)
  end
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:year) { spotify_result(days: 365, breakdowns: { "age" => { "28-34" => 0.6, "35-44" => 0.4 } }) }

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def run = described_class.perform_now(connection.id)

  def audience = podcast.stat_readings.find_by(source: "spotify", metric: "spotify_audience")

  def kept_audience(captured_at: 8.days.ago)
    create(:stat_reading, podcast: podcast, source: "spotify", metric: "spotify_audience", trust: "verified", value: 900,
                          period_days: 30, breakdown: { "age" => { "18-22" => 1.0 } }, captured_at: captured_at)
  end

  it "reads the last 12 months through the throttle and saves only the audience" do
    allow(Stats::PlatformFetch).to receive(:call).and_return(year)
    run

    expect(Stats::PlatformFetch).to have_received(:call).with(connection, session: session, days: 365)
    expect(audience).to have_attributes(period_days: 365, trust: "verified", value: 2_140,
                                        breakdown: { "age" => { "28-34" => 0.6, "35-44" => 0.4 } })
    expect(podcast.stat_readings.pluck(:metric)).to eq([ "spotify_audience" ]) # none of the year's counts
    expect(session.reload.run_log.size).to eq(1)
    expect(described_class.due?(connection)).to be(false)
  end

  it "runs at most once a week per connection, whatever came back" do
    allow(Stats::PlatformFetch).to receive(:call).and_return(fetch_error("failed", "Timed out"))
    kept = kept_audience
    run
    expect(audience.reload.breakdown).to eq(kept.breakdown) # a failed call keeps the last one
    run
    expect(Stats::PlatformFetch).to have_received(:call).once
  end

  it "is due again after a week" do
    create(:stat_reading, podcast: podcast, source: "spotify", metric: "spotify_audience", trust: "verified", value: 1,
                          period_days: 365, captured_at: 6.days.ago)
    expect(described_class.due?(connection)).to be(false)
    travel 2.days
    expect(described_class.due?(connection)).to be(true)
  end

  it "waits its turn under the throttle, enqueued again for the time it's given" do
    session.update_columns(next_run_at: 2.minutes.from_now)
    allow(Stats::PlatformFetch).to receive(:call)
    expect { run }.to have_enqueued_job(described_class).with(connection.id).at(a_value_within(1.second).of(2.minutes.from_now))
    expect(Stats::PlatformFetch).not_to have_received(:call)
  end

  it "asks again after a rate limit, which doesn't count as this week's call" do
    allow(Stats::PlatformFetch).to receive(:call).and_return(fetch_error("rate_limited", "429", retry_after: 300))
    expect { run }.to have_enqueued_job(described_class).with(connection.id).at(a_value_within(1.second).of(300.seconds.from_now))
    expect(described_class.due?(connection)).to be(true)
  end

  it "does nothing for a connection that isn't active, or a show that isn't this one" do
    allow(Stats::PlatformFetch).to receive(:call).and_return(spotify_result(days: 365, show_name: "Someone Else's Pod"))
    connection.update!(status: "failed")
    run
    expect(Stats::PlatformFetch).not_to have_received(:call)

    connection.update!(status: "active")
    run
    expect(audience).to be_nil
  end
end
