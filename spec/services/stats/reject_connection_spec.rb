require "rails_helper"

RSpec.describe Stats::RejectConnection do
  let(:podcast) { create(:podcast, :claimed) }
  let(:connection) do
    create(:stat_connection, podcast: podcast, provider: "apple", external_id: "1234567890", status: "mismatch",
                             last_error: Stats::Ownership::NEEDS_REVIEW)
  end

  it "disconnects a connection held for review with the note, and removes only that platform's numbers" do
    create(:stat_reading, podcast: podcast, source: "apple", trust: "verified", metric: "plays_30d", value: 300)
    create(:stat_reading, podcast: podcast, source: "platforms", trust: "verified", value: 75)
    spotify = create(:stat_reading, podcast: podcast, source: "spotify", trust: "verified", metric: "followers", value: 8)
    provided = create(:stat_reading, podcast: podcast, source: "provided", trust: "provided", value: 500)
    now = Time.utc(2026, 10, 30, 12)

    expect(described_class.call(connection, now: now)).to be(true)

    expect(connection.reload).to have_attributes(status: "disconnected", last_error: StatConnection::REJECTED_MESSAGE,
                                                 last_checked_at: now)
    expect(connection).to be_stopped_by_midrolo
    expect(podcast.stat_readings.reload).to contain_exactly(spotify, provided)
    expect(podcast.reload).to have_attributes(downloads_per_episode: 500, downloads_trust: "provided")
  end

  it "frees the platform show for another page" do
    described_class.call(connection)
    other = build(:stat_connection, podcast: create(:podcast), provider: "apple", external_id: "1234567890")
    expect(other).to be_valid
  end

  it "leaves a connection that isn't held for review alone" do
    connection.update!(last_error: "The Apple Podcasts show at that link isn't this one. Check the link you pasted.")
    reading = create(:stat_reading, podcast: podcast, source: "apple", trust: "verified", metric: "followers", value: 3)

    expect(described_class.call(connection)).to be(false)
    expect(connection.reload.status).to eq("mismatch")
    expect(reading.reload).to be_persisted
  end
end
