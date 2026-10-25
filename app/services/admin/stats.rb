# The admin dashboard's numbers (R68). Each total is { today:, month: } over created_at in the app time zone, from
# one aggregate query per period. Budgets come from Llm::Budget, so the meters show what its gate checks.
module Admin
  class Stats
    FAILED_SHOWN = 20

    def initialize(now: Time.current)
      @periods = { today: now.all_day, month: now.all_month }
    end

    def users = @users ||= per_period { |range| User.where(created_at: range).count }

    # { [kind, status] => count }
    def reports = @reports ||= per_period { |range| Report.where(created_at: range).group(:kind, :status).count }

    # { bucket => USD }
    def spend = @spend ||= per_period { |range| SpendEntry.where(created_at: range).group(:bucket).sum(:cost_usd) }

    # USD per done agent report, nil when there are none.
    def average_agent_cost
      @average_agent_cost ||= per_period { |range| Report.agent.done.where(created_at: range).average(:cost_usd) }
    end

    def pitches = @pitches ||= per_period { |range| Pitch.where(created_at: range).count }

    # { notify:, plans: }: "tell me when reports are back" entries apart from the founding-member list.
    def waitlist
      @waitlist ||= per_period do |range|
        counts = WaitlistEntry.where(created_at: range).group(:price_key).count
        notify = counts.fetch(Billing::NOTIFY_KEY, 0)
        { notify: notify, plans: counts.values.sum - notify }
      end
    end

    def budgets = @budgets ||= Llm::Budget.usage

    def failed_reports
      @failed_reports ||= Report.failed.includes(:show)
                                .order(Report.arel_table[:finished_at].desc.nulls_last, id: :desc).limit(FAILED_SHOWN)
    end

    private

    def per_period(&) = @periods.transform_values(&)
  end
end
