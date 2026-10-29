module Conversations
  # The admin dashboard's requests panel (admin/dashboard/_conversations): today's requests, every conversation by
  # status, blocks, and the latest reported conversations to look at.
  class AdminSummary
    REPORTED_SHOWN = 20

    def initialize(now: Time.current)
      @today = now.all_day
    end

    def requests_today = @requests_today ||= Conversation.where(created_at: @today).count

    # { status => count }, every status present.
    def by_status
      @by_status ||= Conversation::STATUSES.index_with(0).merge(Conversation.group(:status).count)
    end

    def blocks = @blocks ||= Block.count

    def reported
      @reported ||= Conversation.where.not(reported_at: nil).includes(:brand, :podcast)
                                .order(reported_at: :desc, id: :desc).limit(REPORTED_SHOWN).to_a
    end
  end
end
