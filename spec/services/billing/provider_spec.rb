require "rails_helper"

RSpec.describe Billing::Provider do
  describe ".current" do
    it "is Dodo when DODO_API_KEY is set, otherwise the Fake" do
      with_billing_env("DODO_API_KEY" => "key") { expect(described_class.current).to be_a(Billing::Providers::Dodo) }
      with_billing_env do
        expect(described_class.current).to be_a(Billing::Providers::Fake)
        expect(described_class).to be_fake
      end
    end

    it "refuses the Fake in production" do
      allow(Rails.env).to receive(:production?).and_return(true)
      with_billing_env do
        expect { described_class.current }.to raise_error(Billing::MissingCredentials, /DODO_API_KEY/)
      end
    end
  end

  describe ".for" do
    it "gives the adapter for a webhook's provider name, and nil for one it doesn't know" do
      with_billing_env do
        expect(described_class.for("dodo")).to be_a(Billing::Providers::Dodo)
        expect(described_class.for("fake")).to be_a(Billing::Providers::Fake)
        expect(described_class.for("stripe")).to be_nil
        expect(described_class.for(nil)).to be_nil
      end
    end

    it "never gives the Fake in production" do
      allow(Rails.env).to receive(:production?).and_return(true)
      with_billing_env { expect(described_class.for("fake")).to be_nil }
    end
  end

  describe ".test_mode? and .live?" do
    it "reads Dodo's environment, which is test_mode unless DODO_ENVIRONMENT=live_mode" do
      with_billing_env("DODO_API_KEY" => "key") { expect([ described_class.test_mode?, described_class.live? ]).to eq([ true, false ]) }
      with_billing_env("DODO_API_KEY" => "key", "DODO_ENVIRONMENT" => "live_mode") do
        expect([ described_class.test_mode?, described_class.live? ]).to eq([ false, true ])
      end
    end

    it "counts the Fake as test mode outside production, and nothing as either in production without a key" do
      with_billing_env { expect([ described_class.test_mode?, described_class.live? ]).to eq([ true, false ]) }

      allow(Rails.env).to receive(:production?).and_return(true)
      with_billing_env { expect([ described_class.test_mode?, described_class.live? ]).to eq([ false, false ]) }
    end
  end
end
