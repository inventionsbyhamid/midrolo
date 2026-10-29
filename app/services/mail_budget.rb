# The outgoing mail budget (R143). Resend's free tier sends 100 emails a day and 3,000 a month, so whatever anyone
# triggers (sign ups, codes, reports), the app sends at most daily_limit a day and monthly_limit a month
# (MAIL_DAILY_LIMIT, default 90; MAIL_MONTHLY_LIMIT, default 2,800). An ActionMailer interceptor, registered in
# production: every message takes a slot from today's and this month's counters (UTC) before it's sent; over a cap
# it isn't sent (perform_deliveries = false), takes no slot, and the refusal is logged.
#
# Low-priority mail (a message carrying PRIORITY_HEADER: low, as the welcome and runs-resumed mail do) stops at
# LOW_PRIORITY_SHARE of the daily limit, so verification codes and report mail keep the rest of the day. The header
# never leaves the app. Counts move by atomic increments in the shared cache, so every process sees the same totals,
# and a store that can't count holds mail back: the caps protect a hard allowance, as Taste::CallGuard's do.
class MailBudget
  PRIORITY_HEADER = "X-Midrolo-Priority".freeze
  DEFAULT_DAILY_LIMIT = 90
  DEFAULT_MONTHLY_LIMIT = 2800
  LOW_PRIORITY_SHARE = 0.6
  KEY_PREFIX = "mail:sent".freeze

  class << self
    def daily_limit = whole_number(ENV["MAIL_DAILY_LIMIT"], DEFAULT_DAILY_LIMIT)

    def monthly_limit = whole_number(ENV["MAIL_MONTHLY_LIMIT"], DEFAULT_MONTHLY_LIMIT)

    # ActionMailer calls this for every message.
    def delivering_email(message) = new.delivering_email(message)

    private

    def whole_number(value, default)
      number = Integer(value.to_s.strip, 10)
      number.negative? ? default : number
    rescue ArgumentError
      default
    end
  end

  def initialize(store: Rails.cache, clock: -> { Time.now.utc }, daily_limit: self.class.daily_limit,
                 monthly_limit: self.class.monthly_limit)
    @store = store
    @clock = clock
    @daily_limit = daily_limit
    @monthly_limit = monthly_limit
  end

  def delivering_email(message)
    low = message[PRIORITY_HEADER].to_s == "low"
    message[PRIORITY_HEADER] = nil
    reason = take_slot(low:)
    return unless reason

    message.perform_deliveries = false
    Rails.logger.warn("[Mail] not sent, #{reason}: #{message.subject.to_s.truncate(80).inspect}")
  end

  private

  # nil when a slot was taken, else why not (having taken none).
  def take_slot(low:)
    day_cap = low ? (@daily_limit * LOW_PRIORITY_SHARE).floor : @daily_limit
    day = @store.increment(day_key, 1, expires_in: 2.days)
    return give_back([], "the mail counter is unavailable") if day.nil?
    return give_back([ day_key ], "today's #{day_cap} emails are used up") if day > day_cap

    month = @store.increment(month_key, 1, expires_in: 32.days)
    return give_back([ day_key ], "the mail counter is unavailable") if month.nil?
    return give_back([ day_key, month_key ], "this month's #{@monthly_limit} emails are used up") if month > @monthly_limit

    nil
  end

  def give_back(keys, reason)
    keys.each { |key| @store.decrement(key, 1, expires_in: 2.days) }
    reason
  end

  def day_key = "#{KEY_PREFIX}:day:#{@clock.call.utc.strftime('%Y-%m-%d')}"

  def month_key = "#{KEY_PREFIX}:month:#{@clock.call.utc.strftime('%Y-%m')}"
end
