require "rails_helper"

RSpec.describe PitchesHelper do
  describe "#gmail_compose_url" do
    it "builds Gmail's compose URL with the subject and body URL-encoded" do
      pitch = Pitch.new(subject: "Coffee & The Founder's Ledger?", body: "Hi Sam,\n\nA 4-episode bundle is $198 = 10% off.\nThanks")

      expect(helper.gmail_compose_url(pitch)).to eq(
        "https://mail.google.com/mail/?view=cm&fs=1" \
        "&su=Coffee%20%26%20The%20Founder%27s%20Ledger%3F" \
        "&body=Hi%20Sam%2C%0A%0AA%204-episode%20bundle%20is%20%24198%20%3D%2010%25%20off.%0AThanks"
      )
    end
  end

  describe "#pitch_written?" do
    it "knows which of a report's matches have a pitch, with one query per report" do
      report = create(:report, kind: "agent", status: "done")
      pitched, fresh = create_list(:sponsor_match, 2, report: report)
      Pitch.create!(sponsor_match: pitched)

      queries = 0
      counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        expect(helper.pitch_written?(pitched)).to be true
        expect(helper.pitch_written?(fresh)).to be false
      end
      expect(queries).to eq(1)
    end
  end
end
