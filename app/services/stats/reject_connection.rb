module Stats
  # An admin's Reject on a connection held for review (Stats::Ownership::NEEDS_REVIEW, /admin/stat_connections): the
  # platform show isn't this podcast. The connection is disconnected with StatConnection::REJECTED_MESSAGE, which its
  # maker reads on the Stats screen; the podcast loses that platform's readings and the plays per episode made from
  # them, and its listing columns are refreshed (Podcast#remove_stat_source!). A disconnected connection holds no
  # platform show, so the real show's owner can connect it. Returns false, changing nothing, when the connection is no
  # longer held for review (an approval or a sync got there first).
  class RejectConnection
    def self.call(connection, now: Time.current) = new(connection, now).call

    def initialize(connection, now)
      @connection = connection
      @now = now
    end

    def call
      rejected = false
      @connection.with_lock do
        if Ownership.needs_review?(@connection)
          @connection.update!(status: "disconnected", last_error: StatConnection::REJECTED_MESSAGE, last_checked_at: @now)
          @connection.podcast.remove_stat_source!(@connection.provider)
          rejected = true
        end
      end
      rejected
    end
  end
end
