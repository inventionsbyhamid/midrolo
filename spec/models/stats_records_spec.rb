require "rails_helper"

RSpec.describe "Stats records" do
  describe StatReading do
    it "has the four trust levels, least trusted first" do
      expect(StatReading::TRUST_LEVELS).to eq(%w[feed public provided verified])
      expect(build(:stat_reading, trust: "rumor")).not_to be_valid
      expect(build(:stat_reading, value: -1)).not_to be_valid
    end

    it "is one per podcast, metric and source, and counts until it expires" do
      reading = create(:stat_reading, source: "spotify", trust: "verified")
      expect(build(:stat_reading, podcast: reading.podcast, source: "spotify")).not_to be_valid

      expired = create(:stat_reading, source: "apple", expires_at: 1.minute.ago)
      lasting = create(:stat_reading, source: "show", expires_at: nil)
      expect(StatReading.unexpired).to contain_exactly(reading, lasting)
      expect(StatReading.expired).to eq([ expired ])
      expect(expired).to be_expired
    end

    it "keeps audience breakdowns" do
      reading = create(:stat_reading, metric: "spotify_audience", breakdown: { "age" => { "18-24" => 0.3 } })
      expect(reading.reload.breakdown).to eq("age" => { "18-24" => 0.3 })
    end
  end

  describe StatConnection do
    it "stores credentials encrypted and takes the platforms and states of an invite" do
      connection = create(:stat_connection, credentials: "session-cookie")
      stored = StatConnection.connection.select_value("SELECT credentials FROM stat_connections WHERE id = #{connection.id}")
      expect(stored).not_to include("session-cookie")
      expect(connection.reload.credentials).to eq("session-cookie")

      expect(StatConnection::PROVIDERS).to include("spotify", "apple")
      expect(StatConnection::STATUSES).to eq(%w[pending_invite active mismatch failed disconnected])
      expect(connection).to be_pending_invite
      expect(build(:stat_connection, provider: "myspace")).not_to be_valid
      expect(build(:stat_connection, podcast: connection.podcast, provider: "spotify")).not_to be_valid
    end

    it "lets one page at a time hold a platform show, while pending or active, with a message naming no show" do
      held = create(:stat_connection, provider: "spotify", external_id: "show-1", status: "active")

      twin = build(:stat_connection, provider: "spotify", external_id: "show-1")
      expect(twin).not_to be_valid
      expect(twin.errors.full_messages).to eq([ "This show is already connected to another Midrolo page." ])
      expect(build(:stat_connection, provider: "apple", external_id: "show-1")).to be_valid
      expect(build(:stat_connection, provider: "spotify", external_id: "show-1", status: "mismatch")).to be_valid

      held.update!(status: "disconnected")
      expect(twin).to be_valid
      twin.save!
      expect { held.update!(status: "active") }.to raise_error(ActiveRecord::RecordInvalid)
      # The database holds the line too, past the validation.
      expect { held.update_column(:status, "pending_invite") }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe ServiceSession do
    it "is one per platform, with its credentials encrypted and filtered" do
      session = create(:service_session, credentials: "sp_dc=abc")
      stored = ServiceSession.connection.select_value("SELECT credentials FROM service_sessions WHERE id = #{session.id}")
      expect(stored).not_to include("sp_dc=abc")
      expect(session.inspect).not_to include("sp_dc=abc")
      expect(build(:service_session, platform: "spotify")).not_to be_valid
      expect(build(:service_session, platform: "youtube")).not_to be_valid
      expect(build(:service_session, platform: "apple", status: "fine")).not_to be_valid
    end
  end
end
