require "rails_helper"

RSpec.describe Taste::Provider do
  around do |ex|
    keep = ENV["QLOO_API_KEY"]
    ex.run
    keep ? ENV["QLOO_API_KEY"] = keep : ENV.delete("QLOO_API_KEY")
    described_class.reset!
  end

  before do
    ENV.delete("QLOO_API_KEY")
    described_class.reset!
  end

  it "returns Qloo when the key is present" do
    ENV["QLOO_API_KEY"] = "k"
    expect(described_class.current).to be_a(Taste::Providers::Qloo)
    expect(described_class.fake?).to be(false)
  end

  it "returns Fake when the key is missing outside production" do
    expect(described_class.current).to be_a(Taste::Providers::Fake)
    expect(described_class.fake?).to be(true)
  end

  it "memoizes until reset!" do
    first = described_class.current
    expect(described_class.current).to equal(first)
    described_class.reset!
    expect(described_class.current).not_to equal(first)
  end

  it "raises a clear error in production without the key" do
    allow(Rails.env).to receive(:production?).and_return(true)
    expect { described_class.current }.to raise_error(Taste::MissingCredentials, /QLOO_API_KEY/)
  end
end
