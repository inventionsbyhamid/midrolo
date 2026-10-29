# Stats::Throttle keeps Midrolo's own Spotify and Apple accounts light and polite, per platform, on its service session
# row (changed only under that row's lock): when the next helper run may start (a run's lease, then the gap after it,
# or a pause after failures), the time last handed to a waiting job, the cooldown after a rate-limited answer and how
# many came in a row, failed runs in a row, and the start times of the runs in the last 24 hours (epoch seconds, for
# the hourly and daily caps).
class AddThrottleToServiceSessions < ActiveRecord::Migration[8.1]
  def change
    change_table :service_sessions, bulk: true do |t|
      t.datetime :next_run_at
      t.datetime :queued_until
      t.datetime :cooldown_until
      t.integer :rate_limits_in_a_row, null: false, default: 0
      t.datetime :last_rate_limited_at
      t.integer :failures_in_a_row, null: false, default: 0
      t.jsonb :run_log, null: false, default: []
    end
  end
end
