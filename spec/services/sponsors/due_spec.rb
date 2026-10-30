require "rails_helper"

RSpec.describe Sponsors::Due do
  let(:podcast) { create(:podcast, :active) }

  before { allow(Llm).to receive(:mode).and_return(:live) }

  def episode(published_at, **attributes) = create(:episode, podcast: podcast, published_at: published_at, **attributes)

  it "holds episodes never checked, published inside the window and not after now" do
    recent = episode(2.days.ago)
    episode(40.days.ago)
    episode(2.days.from_now) # scheduled: due once it is out (review L1)
    episode(1.day.ago, sponsor_ai_checked_at: 1.hour.ago)
    patterned = episode(3.days.ago, sponsor_scanned_at: 3.days.ago)

    expect(described_class.episodes).to contain_exactly(recent, patterned)
    expect(described_class.for_run(podcast.episodes).to_a).to eq([ recent, patterned ])
  end

  it "holds none when the window is 0, and widens with sponsors_ai_window_days" do
    old = episode(40.days.ago)

    AppSettings.set(:sponsors_ai_window_days, 0)
    episode(1.hour.ago)
    expect(described_class.episodes).to be_empty
    expect(described_class.podcasts).to be_empty

    AppSettings.set(:sponsors_ai_window_days, 60)
    expect(described_class.episodes).to include(old)
  end
end
