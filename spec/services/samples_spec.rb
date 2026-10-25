require "rails_helper"

RSpec.describe Samples do
  describe ".entries" do
    around do |example|
      saved = described_class.instance_variable_get(:@entries)
      described_class.instance_variable_set(:@entries, nil)
      example.run
    ensure
      described_class.instance_variable_set(:@entries, saved)
    end

    it "reads samples.yml once per process" do
      allow(Rails.application).to receive(:config_for).and_call_original

      2.times { expect(described_class.slugs).to eq(%w[sample-one sample-two sample-three]) }
      expect(Rails.application).to have_received(:config_for).with(:samples).once
    end

    it "reads it on every call in development, so an edit shows up without a restart" do
      allow(Rails.env).to receive(:development?).and_return(true)
      allow(Rails.application).to receive(:config_for).and_call_original

      2.times { described_class.entries }
      expect(Rails.application).to have_received(:config_for).with(:samples).twice
    end
  end
end
