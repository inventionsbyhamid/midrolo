module Stats
  # Stub (lane L5 fills it), recurring daily (config/recurring.yml): refreshes the listing columns of podcasts whose
  # readings expired since the last run (Podcast#refresh_listing!), so an expired number stops counting as verified.
  class ExpireReadingsJob < ApplicationJob
    queue_as :stats
    queue_with_priority 10

    def perform; end
  end
end
