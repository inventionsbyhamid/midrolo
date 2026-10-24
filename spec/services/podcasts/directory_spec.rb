require "rails_helper"

RSpec.describe Podcasts::Directory do
  around do |ex|
    keep = ENV.to_h.slice("PODCAST_INDEX_KEY", "PODCAST_INDEX_SECRET")
    ex.run
    ENV.delete("PODCAST_INDEX_KEY")
    ENV.delete("PODCAST_INDEX_SECRET")
    keep.each { |k, v| ENV[k] = v }
    described_class.reset!
  end

  before do
    ENV.delete("PODCAST_INDEX_KEY")
    ENV.delete("PODCAST_INDEX_SECRET")
    described_class.reset!
  end

  it "returns the PodcastIndex adapter when both keys are present" do
    ENV["PODCAST_INDEX_KEY"] = "k"
    ENV["PODCAST_INDEX_SECRET"] = "s"
    expect(described_class.current).to be_a(Podcasts::Directories::PodcastIndex)
  end

  it "returns Fake when a key is missing outside production" do
    ENV["PODCAST_INDEX_KEY"] = "k"
    expect(described_class.current).to be_a(Podcasts::Directories::Fake)
  end

  it "memoizes until reset!" do
    first = described_class.current
    expect(described_class.current).to equal(first)
    described_class.reset!
    expect(described_class.current).not_to equal(first)
  end

  it "raises naming the missing env vars in production" do
    allow(Rails.env).to receive(:production?).and_return(true)
    expect { described_class.current }.to raise_error(Podcasts::Directory::MissingCredentials, /PODCAST_INDEX_KEY.*PODCAST_INDEX_SECRET/)
  end

  it "reports whether the fake adapter is active" do
    expect(described_class.fake?).to be(true)
  end
end
