module Catalog
  # Stub (lane L1 fills it), recurring every 10 minutes (config/recurring.yml): leases podcasts due for a feed check
  # (Podcast.due_for_fetch, FOR UPDATE SKIP LOCKED, podcasts.leased_until), a batch at a time, grouped by feed host, and
  # enqueues their ingest.
  class RefreshDueJob < ApplicationJob
    queue_as :catalog

    def perform; end
  end
end
