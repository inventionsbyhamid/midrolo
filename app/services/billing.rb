# Vendor-neutral billing (spec §9a, §11). Use Billing::Provider.current; never call a vendor SDK directly. Prices and
# plans are ours (config/plans.yml); webhooks only change subscriptions through Billing::Event and Billing::Sync.
#
# Billing.mode (R66), from BILLING_MODE:
#   :waitlist (the default): paid buttons join the founding-member waitlist and checkout is shut, except that judges
#             and admins may try it against a provider in test mode (spec §15).
#   :test     checkout is open to every signed-in user against a provider in test mode. For staging.
#   :live     real payments. Needs DODO_API_KEY and DODO_ENVIRONMENT=live_mode, and the go-live check (R94,
#             Billing::Margins): the Qloo cost per call set and every paid plan keeping 60% or more at its caps.
# A mode its provider can't back, or live before the go-live check passes, falls back to :waitlist, with a warning.
module Billing
  class Error < StandardError; end
  # A webhook whose signature, or signature headers, don't check out.
  class InvalidSignature < Error; end
  # A key, webhook secret or product id isn't set.
  class MissingCredentials < Error; end
  # The provider's API failed: network, auth or an unusable answer.
  class Unavailable < Error; end

  # One price a plan is sold at. interval is :monthly, :yearly or :once; usd is the price in dollars.
  Price = Data.define(:key, :plan, :interval, :usd)

  # Waitlist entries for "tell me when reports are back" (Task 18) rather than a price.
  NOTIFY_KEY = "notify".freeze

  class << self
    def mode
      requested = ENV["BILLING_MODE"].to_s.strip.downcase.presence || "waitlist"
      case requested
      when "waitlist" then :waitlist
      when "live"
        return fall_back("BILLING_MODE=live needs DODO_API_KEY and DODO_ENVIRONMENT=live_mode") unless Provider.live?

        blockers = Margins.check.blockers
        blockers.empty? ? :live : fall_back("BILLING_MODE=live waits for the go live check: #{blockers.join('; ')}")
      when "test"
        Provider.test_mode? ? :test : fall_back("BILLING_MODE=test needs a payment provider in test mode")
      else fall_back("unknown BILLING_MODE #{requested.inspect}")
      end
    end

    # What keeps BILLING_MODE=live from going live, for the admin page (R94): [] unless live is asked for. check: a
    # Margins.check already made.
    def go_live_blockers(check = nil)
      return [] unless ENV["BILLING_MODE"].to_s.strip.downcase == "live"

      setup = "payments aren't set up for live mode (DODO_API_KEY and DODO_ENVIRONMENT=live_mode)" unless Provider.live?
      [ setup, *(check || Margins.check).blockers ].compact
    end

    # Whether user may start a checkout now (R66). Never raises, whatever is configured.
    def checkout_open?(user)
      return false unless user

      case mode
      when :test, :live then true
      else (user.judge? || user.admin?) && Provider.test_mode?
      end
    end

    # The waitlist's exception: a judge or admin may also try checkout in test mode.
    def test_checkout?(user) = mode == :waitlist && checkout_open?(user)

    # Whether a verified payment from provider (a provider name) may give user a plan (R75b): when the provider takes
    # live payments, or when checkout is open to the user. So a test-mode payment link made out to any user id grants
    # nothing on the waitlist, unless that user is a judge or admin.
    def grant_allowed?(user, provider:)
      return false unless user

      (Provider.live? && provider == Provider.current.name) || checkout_open?(user)
    end

    # The entitling subscription that stops user buying price, or nil: any one stops a recurring plan; only a recurring
    # one stops the sprint, since a second sprint extends the first.
    def blocking_subscription(user, price)
      Subscription.best_for(user, plans: price.plan == "sprint" ? Subscription::PLANS - [ "sprint" ] : Subscription::PLANS)
    end

    # The subscription whose customer portal "Manage billing" opens, in any mode (R73): the user's latest one with a
    # customer id, or nil.
    def portal_subscription(user)
      user.subscriptions.where.not(provider_customer_id: [ nil, "" ]).order(:updated_at, :id).last
    end

    # Every price in plans.yml, in its order.
    def prices
      Entitlements.plans.flat_map do |plan, settings|
        next [] unless settings.is_a?(Hash) && settings[:price_keys].is_a?(Hash)

        settings[:price_keys].map do |interval, key|
          Price.new(key: key.to_s, plan: plan.to_s, interval: interval, usd: settings[:"price_#{interval}_usd"])
        end
      end
    end

    def price(key) = prices.find { |price| price.key == key.to_s }

    # "creator_yearly" => "creator", "sprint" => "sprint"; nil for anything else.
    def plan_for(price_key) = price(price_key)&.plan

    # The keys a waitlist entry may name.
    def waitlist_keys = prices.map(&:key) << NOTIFY_KEY

    # The provider's product id for a price key (plans.yml product_ids, from ENV), or nil when unset.
    def product_id(price_key) = product_ids[price_key.to_s.to_sym].presence

    def price_key_for_product(product_id)
      return if product_id.blank?

      product_ids.find { |_key, id| id.to_s == product_id.to_s }&.first&.to_s
    end

    # Forgets the memoized provider, plans.yml and the warnings given (after ENV changes, in specs).
    def reset!
      Provider.reset!
      Entitlements.reset_plans!
      @warned = nil
    end

    private

    def product_ids = Entitlements.plans[:product_ids] || {}

    def fall_back(reason)
      @warned ||= Set.new
      Rails.logger.warn("[Billing] #{reason}; showing the waitlist instead") if @warned.add?(reason)
      :waitlist
    end
  end
end
