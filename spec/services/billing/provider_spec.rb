require "rails_helper"

RSpec.describe Billing::Provider do
  describe ".current" do
    it "is Dodo when DODO_API_KEY is set, otherwise the Fake" do
      with_billing_env("DODO_API_KEY" => "key") { expect(described_class.current).to be_a(Billing::Providers::Dodo) }
      with_billing_env { expect(described_class.current).to be_a(Billing::Providers::Fake) }
    end

    it "refuses the Fake in production" do
      allow(Rails.env).to receive(:production?).and_return(true)
      with_billing_env do
        expect { described_class.current }.to raise_error(Billing::MissingCredentials, /DODO_API_KEY/)
      end
    end
  end

  describe "choosing the provider (R145)" do
    it "takes BILLING_PROVIDER first, whatever else is set" do
      with_billing_env("BILLING_PROVIDER" => "fake", "DODO_API_KEY" => "key") do
        expect(described_class.chosen_name).to eq("fake")
        expect(described_class.current).to be_a(Billing::Providers::Fake)
      end
      with_billing_env("BILLING_PROVIDER" => "dodo", "DODO_API_KEY" => "key") do
        expect(described_class.current).to be_a(Billing::Providers::Dodo)
      end
    end

    it "refuses an unknown or unconfigured BILLING_PROVIDER in production, naming what to set" do
      allow(Rails.env).to receive(:production?).and_return(true)
      with_billing_env("BILLING_PROVIDER" => "stripe") do
        expect { described_class.current }.to raise_error(Billing::MissingCredentials, /BILLING_PROVIDER/)
        expect([ described_class.test_mode?, described_class.live? ]).to eq([ false, false ])
      end
      with_billing_env("BILLING_PROVIDER" => "dodo") do
        expect { described_class.current }.to raise_error(Billing::MissingCredentials, /DODO_API_KEY/)
      end
    end

    it "registers every adapter with the whole contract, so a new provider is one class and one registry line" do
      described_class::ADAPTERS.each do |name, class_name|
        adapter = class_name.constantize
        expect(adapter::NAME).to eq(name)
        expect(adapter).to respond_to(:configured?, :environment, :setup, :live_setup, :fees)
        expect(adapter.fees.keys).to eq(%i[rate fixed_usd])
        expect(adapter.instance_methods).to include(:name, :test_mode?, :checkout_url, :portal_url, :verify!, :parse)
      end
    end

    it "takes the fees from the chosen adapter, and the conservative default without one" do
      with_billing_env("DODO_API_KEY" => "key") { expect(described_class.fees).to eq(Billing::Providers::Dodo.fees) }
      allow(Rails.env).to receive(:production?).and_return(true)
      with_billing_env { expect(described_class.fees).to eq(described_class::DEFAULT_FEES) }
    end

    it "says what live mode needs in the chosen provider's words" do
      with_billing_env("DODO_API_KEY" => "key") { expect(described_class.live_setup).to eq("DODO_API_KEY and DODO_ENVIRONMENT=live_mode") }
      with_billing_env { expect(described_class.live_setup).to include("DODO_API_KEY") }
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
