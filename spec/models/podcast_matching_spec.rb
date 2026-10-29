require "rails_helper"

RSpec.describe Podcast::Matching do
  describe "#taste_report (lane L8: the report the podcast page reads instead of calling Qloo)" do
    let(:podcast) { create(:podcast, :active) }
    let(:samples_owner) { User.find_or_create_by!(email: User::SAMPLES_EMAIL) }
    let(:owner_show) { create(:show, podcast: podcast, verified_at: 1.day.ago) }
    let(:sample_show) { create(:show, user: samples_owner, podcast: podcast) }

    def report(show, kind: "agent", status: "done", finished: 1.day.ago, **attrs)
      create(:report, show: show, kind: kind, status: status, finished_at: finished, **attrs)
    end

    it "is nil without an owner's or a sample's done report" do
      report(create(:show, podcast: podcast)) # someone else's workspace for the podcast, unverified
      report(owner_show, status: "failed")
      report(sample_show) # a sample show's report that isn't a listed sample
      expect(podcast.taste_report).to be_nil
    end

    it "takes the owner's report before a sample's, a full report before a Snapshot, then the newest" do
      sample = report(sample_show, sample_slug: Samples.slugs[0], finished: 1.hour.ago)
      expect(podcast.taste_report).to eq(sample)

      old_full = report(owner_show, finished: 3.days.ago)
      report(owner_show, kind: "snapshot", finished: 1.hour.ago)
      expect(podcast.taste_report).to eq(old_full)

      newer_full = report(owner_show, finished: 2.days.ago)
      report(owner_show, finished: nil, status: "running")
      expect(podcast.taste_report).to eq(newer_full)
    end

    it "comes with its show and that show's kit loaded" do
      create(:media_kit, show: owner_show)
      report(owner_show)
      found = podcast.taste_report
      expect(found.association(:show)).to be_loaded
      expect(found.show.association(:media_kit)).to be_loaded
    end
  end
end
