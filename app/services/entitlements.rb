# STUB. Task 16 replaces these values with real plan logic (config/plans.yml, promos, judges).
# The interface is final; only the numbers and rules change.
module Entitlements
  # reason is one of :limit, :budget, :paused, :plan
  class NotAllowed < StandardError
    attr_reader :reason

    def initialize(reason = :plan, message = nil)
      @reason = reason
      super(message || "Not allowed: #{reason}")
    end
  end

  class Plan
    def key = :free
    def max_shows = 1
    def can_run?(_kind) = true
    def agent_reports_left(_period_start = nil) = 99
    def snapshots_left = 99
    def pitches_left = 99
    def can_pitch? = true
    def visible_matches_limit = 50
    def kit_badge? = true
    def csv_export? = false
    def scan_limit = 8
  end

  def self.for(_user)
    Plan.new
  end
end
