require "rails_helper"

RSpec.describe DemoMode do
  let(:real) { Object.new }

  before do
    allow(Taste::Provider).to receive(:current).and_return(real)
    allow(Podcasts::Directory).to receive(:current).and_return(real)
    allow(Llm).to receive(:mode).and_return(:live)
  end

  it "is inactive when everything is real" do
    expect(described_class.active?).to be(false)
  end

  it "is active with a fake taste provider" do
    allow(Taste::Provider).to receive(:current).and_return(Taste::Providers::Fake.new)
    expect(described_class.active?).to be(true)
  end

  it "is active with a fake directory" do
    allow(Podcasts::Directory).to receive(:current).and_return(Podcasts::Directories::Fake.new)
    expect(described_class.active?).to be(true)
  end

  it "is active in fake llm mode" do
    allow(Llm).to receive(:mode).and_return(:fake)
    expect(described_class.active?).to be(true)
  end
end
