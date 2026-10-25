require "rails_helper"

RSpec.describe Billing do
  describe ".mode (R66)" do
    it "is the waitlist when BILLING_MODE is unset or blank" do
      with_billing_env { expect(described_class.mode).to eq(:waitlist) }
      with_billing_env("BILLING_MODE" => " ") { expect(described_class.mode).to eq(:waitlist) }
    end

    it "is test with a provider in test mode: the Fake here, or Dodo with DODO_ENVIRONMENT=test_mode" do
      with_billing_env("BILLING_MODE" => "test") { expect(described_class.mode).to eq(:test) }
      with_billing_env("BILLING_MODE" => "test", "DODO_API_KEY" => "key", "DODO_ENVIRONMENT" => "test_mode") do
        expect(described_class.mode).to eq(:test)
      end
    end

    it "is live only with DODO_API_KEY and DODO_ENVIRONMENT=live_mode" do
      with_billing_env("BILLING_MODE" => "live", "DODO_API_KEY" => "key", "DODO_ENVIRONMENT" => "live_mode") do
        expect(described_class.mode).to eq(:live)
      end
    end

    it "falls back to the waitlist, with a warning, when live isn't configured for live payments" do
      allow(Rails.logger).to receive(:warn)
      with_billing_env("BILLING_MODE" => "live") { expect(described_class.mode).to eq(:waitlist) }
      with_billing_env("BILLING_MODE" => "live", "DODO_API_KEY" => "key") { expect(described_class.mode).to eq(:waitlist) }
      with_billing_env("BILLING_MODE" => "live", "DODO_ENVIRONMENT" => "live_mode") { expect(described_class.mode).to eq(:waitlist) }

      expect(Rails.logger).to have_received(:warn).with(/BILLING_MODE=live needs DODO_API_KEY and DODO_ENVIRONMENT=live_mode/).at_least(:once)
    end

    it "warns once per misconfiguration, not on every call" do
      allow(Rails.logger).to receive(:warn)
      with_billing_env("BILLING_MODE" => "live") { 3.times { described_class.mode } }

      expect(Rails.logger).to have_received(:warn).once
    end

    it "never runs test mode against live payments: it falls back to the waitlist" do
      allow(Rails.logger).to receive(:warn)
      with_billing_env("BILLING_MODE" => "test", "DODO_API_KEY" => "key", "DODO_ENVIRONMENT" => "live_mode") do
        expect(described_class.mode).to eq(:waitlist)
      end
      expect(Rails.logger).to have_received(:warn).with(/BILLING_MODE=test needs/)
    end

    it "falls back to the waitlist on an unknown mode" do
      allow(Rails.logger).to receive(:warn)
      with_billing_env("BILLING_MODE" => "free-for-all") { expect(described_class.mode).to eq(:waitlist) }
      expect(Rails.logger).to have_received(:warn).with(/unknown BILLING_MODE "free-for-all"/)
    end
  end

  describe "prices" do
    it "lists every price key in plans.yml with its plan, interval and price" do
      expect(described_class.prices.map { |price| [ price.key, price.plan, price.interval, price.usd ] }).to eq([
        [ "creator_monthly", "creator", :monthly, 19 ], [ "creator_yearly", "creator", :yearly, 190 ],
        [ "pro_monthly", "pro", :monthly, 49 ], [ "pro_yearly", "pro", :yearly, 490 ], [ "sprint", "sprint", :once, 49 ]
      ])
    end

    it "maps a price key to its plan, and nothing else to any plan" do
      expect(described_class.plan_for("creator_yearly")).to eq("creator")
      expect(described_class.plan_for("pro_monthly")).to eq("pro")
      expect(described_class.plan_for("sprint")).to eq("sprint")
      expect(described_class.plan_for("notify")).to be_nil
      expect(described_class.plan_for(nil)).to be_nil
    end

    it "maps price keys to provider product ids from ENV, and back" do
      with_billing_env("DODO_PRODUCT_PRO_YEARLY" => "pdt_pro_yearly") do
        expect(described_class.product_id("pro_yearly")).to eq("pdt_pro_yearly")
        expect(described_class.product_id("pro_monthly")).to be_nil
        expect(described_class.price_key_for_product("pdt_pro_yearly")).to eq("pro_yearly")
        expect(described_class.price_key_for_product("pdt_unknown")).to be_nil
        expect(described_class.price_key_for_product(nil)).to be_nil
      end
    end

    it "takes the waitlist's own notify key as well as the price keys" do
      expect(described_class.waitlist_keys).to eq(%w[creator_monthly creator_yearly pro_monthly pro_yearly sprint notify])
    end
  end

  describe ".checkout_open? (R66)" do
    let(:user) { create(:user) }
    let(:judge) { create(:user, judge: true) }
    let(:admin) { create(:user, admin: true) }

    it "is open to every signed-in user in test and live modes" do
      with_billing_env("BILLING_MODE" => "test") do
        expect(described_class.checkout_open?(user)).to be true
        expect(described_class.checkout_open?(nil)).to be false
      end
      with_billing_env("BILLING_MODE" => "live", "DODO_API_KEY" => "key", "DODO_ENVIRONMENT" => "live_mode") do
        expect(described_class.checkout_open?(user)).to be true
      end
    end

    it "is shut to the public on the waitlist, but open to judges and admins against a provider in test mode" do
      with_billing_env do
        expect(described_class.checkout_open?(user)).to be false
        expect(described_class.checkout_open?(judge)).to be true
        expect(described_class.checkout_open?(admin)).to be true
        expect(described_class.test_checkout?(judge)).to be true
        expect(described_class.test_checkout?(user)).to be false
      end
      with_billing_env("DODO_API_KEY" => "key", "DODO_ENVIRONMENT" => "test_mode") do
        expect(described_class.checkout_open?(judge)).to be true
      end
    end

    it "is shut to judges on the waitlist when the provider takes live payments" do
      with_billing_env("DODO_API_KEY" => "key", "DODO_ENVIRONMENT" => "live_mode") do
        expect(described_class.checkout_open?(judge)).to be false
        expect(described_class.test_checkout?(judge)).to be false
      end
    end

    it "offers the secondary test checkout only on the waitlist" do
      with_billing_env("BILLING_MODE" => "test") { expect(described_class.test_checkout?(judge)).to be false }
    end
  end

  describe ".portal_subscription" do
    let(:user) { create(:user) }

    it "is the user's latest subscription with a customer id at the current provider, where checkout is open" do
      with_billing_env("BILLING_MODE" => "test") do
        create(:subscription, user: user, provider: "fake", provider_customer_id: "cus_old", updated_at: 2.days.ago)
        latest = create(:subscription, user: user, provider: "fake", provider_customer_id: "cus_new")
        create(:subscription, user: user, provider: "fake", provider_customer_id: nil)
        create(:subscription, user: user, provider: "dodo", provider_customer_id: "cus_elsewhere")

        expect(described_class.portal_subscription(user)).to eq(latest)
      end
    end

    it "is nil without a customer id, or on the waitlist" do
      with_billing_env("BILLING_MODE" => "test") do
        create(:subscription, user: user, provider: "fake", provider_customer_id: nil)
        expect(described_class.portal_subscription(user)).to be_nil
      end
      with_billing_env do
        create(:subscription, user: user, provider: "fake", provider_customer_id: "cus_1")
        expect(described_class.portal_subscription(user)).to be_nil
      end
    end
  end
end
