module Billing
  # Applies one Billing::Event to our subscriptions (spec §9a): the only code that writes them from webhooks. It stays
  # right on replays and on events out of order (Review Focus #5):
  #   - a subscription is found by (provider, provider_subscription_id) first; only a new one takes its user from the
  #     event (our checkout's metadata, trusted because the webhook's signature checked out);
  #   - only an activating event (active, renewed, the sprint's payment) creates, extends or reactivates, and only
  #     when Billing.grant_allowed? (R75b): live payments, or a user checkout is open to;
  #   - current_period_end only moves forward, and only on an activating event (R76): a failed renewal never carries
  #     a row through a period nobody paid for. current_period_start moves with it;
  #   - status, plan and cancel_at_period_end come only from an event at least as new as the last one applied
  #     (last_event_at), so a late "renewed" never undoes a newer "canceled";
  #   - a sprint payment applies once, by its payment id, whatever webhook id delivers it.
  # Rows are locked, so concurrent events for one subscription, or one user's sprints, take turns.
  #
  # apply returns nil, or (logged) why the event changed nothing.
  class Sync
    # A cancellation or failed payment for a subscription whose start we haven't seen: ProcessBillingEventJob tries
    # again once the start event has had time to arrive.
    class UnknownSubscription < Error; end
    # Why an event changes nothing (no user, an unknown price key): noted on its BillingEvent.
    class Skipped < Error; end

    STATUSES = { subscription_active: "active", subscription_renewed: "active", subscription_canceled: "canceled",
                 payment_failed: "past_due" }.freeze
    # The events that may create, extend or reactivate a subscription: each means it's paid for.
    ACTIVATING = %i[subscription_active subscription_renewed].freeze
    SUBSCRIPTION_PLANS = %w[creator pro].freeze

    def self.apply(event) = new(event).apply

    def initialize(event)
      @event = event
    end

    def apply
      case @event.type
      when :one_time_paid then apply_one_time_payment
      when *STATUSES.keys then apply_subscription_event
      end
      nil
    rescue Skipped => e
      Rails.logger.error("[Billing::Sync] #{e.message} (#{@event.provider} #{@event.name} #{@event.id})")
      e.message
    end

    private

    def apply_subscription_event
      raise Skipped, "The event has no subscription id" if @event.subscription_id.blank?

      Subscription.transaction do
        subscription = Subscription.lock.find_by(provider: @event.provider, provider_subscription_id: @event.subscription_id)
        update_subscription(subscription || start_subscription)
      end
    end

    def start_subscription
      raise UnknownSubscription, "No subscription #{@event.subscription_id} to update yet" unless activating?
      raise Skipped, "No user for this event (user_id #{@event.user_id.inspect})" unless user

      plan = Billing.plan_for(@event.price_key)
      raise Skipped, "No subscription plan for price key #{@event.price_key.inspect}" unless SUBSCRIPTION_PLANS.include?(plan)

      user.subscriptions.new(provider: @event.provider, provider_subscription_id: @event.subscription_id, plan: plan,
                             price_key: @event.price_key, status: "active")
    end

    def update_subscription(subscription)
      if activating?
        ensure_grant_allowed!(subscription.user)
        extend_period(subscription)
      end
      subscription.provider_customer_id = @event.customer_id if @event.customer_id.present?
      apply_newest(subscription) if newest?(subscription)
      subscription.save!
    end

    def apply_newest(subscription)
      subscription.status = STATUSES.fetch(@event.type)
      subscription.cancel_at_period_end = @event.cancel_at_period_end unless @event.cancel_at_period_end.nil?
      plan = Billing.plan_for(@event.price_key)
      subscription.assign_attributes(plan: plan, price_key: @event.price_key) if SUBSCRIPTION_PLANS.include?(plan)
      subscription.last_event_at = @event.occurred_at if @event.occurred_at
    end

    def extend_period(subscription)
      if @event.period_end && (subscription.current_period_end.nil? || @event.period_end > subscription.current_period_end)
        subscription.current_period_end = @event.period_end
        subscription.current_period_start = @event.period_start if @event.period_start
      end
      subscription.current_period_start ||= @event.period_start
    end

    def activating? = ACTIVATING.include?(@event.type)

    def ensure_grant_allowed!(user)
      return if Billing.grant_allowed?(user, provider: @event.provider)

      raise Skipped, "No plan granted to user #{user.id}: #{@event.provider} isn't taking live payments and checkout " \
                     "isn't open to this user (billing mode #{Billing.mode})"
    end

    # An event with no time of its own can't be placed, so it changes no status a timed event has set.
    def newest?(subscription)
      subscription.last_event_at.nil? || (@event.occurred_at.present? && @event.occurred_at >= subscription.last_event_at)
    end

    # A Sponsor Sprint: Pro for duration_days (plans.yml) from the payment. Paid again while one runs, it extends that
    # one from its end; otherwise it starts a new one.
    def apply_one_time_payment
      unless Billing.plan_for(@event.price_key) == "sprint"
        raise Skipped, "A one-time payment that is not the sprint (price key #{@event.price_key.inspect})"
      end
      raise Skipped, "No user for this event (user_id #{@event.user_id.inspect})" unless user

      ensure_grant_allowed!(user)
      paid_at = @event.occurred_at || Time.current
      length = Entitlements.limits(:sprint).fetch(:duration_days).days
      Subscription.transaction do
        user.lock! # one user's sprint payments take turns
        raise Skipped, "Payment #{@event.payment_id} was applied already" if payment_applied?

        running = user.subscriptions.where(plan: "sprint", status: "active", current_period_end: Time.current..)
                      .order(:current_period_end).last
        if running
          running.update!(current_period_end: running.current_period_end + length,
                          last_event_at: [ running.last_event_at, paid_at ].compact.max,
                          payment_ids: running.payment_ids + Array(@event.payment_id))
        else
          user.subscriptions.create!(provider: @event.provider, provider_customer_id: @event.customer_id, plan: "sprint",
                                     price_key: "sprint", status: "active", current_period_start: paid_at,
                                     current_period_end: paid_at + length, last_event_at: paid_at,
                                     payment_ids: Array(@event.payment_id))
        end
      end
    end

    def payment_applied?
      @event.payment_id.present? &&
        Subscription.where(provider: @event.provider).where("? = ANY (payment_ids)", @event.payment_id).exists?
    end

    def user = @user ||= User.find_by(id: @event.user_id)
  end
end
