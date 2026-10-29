module Catalog
  # Stub (lane L1 fills it): a directory search that grows the catalog. Searches the catalog first (full text and
  # trigram); with fewer than 5 hits, asks Podcasts::Directory.current, creates up to 5 missing podcasts as pending
  # (source "search") and enqueues their ingest at high priority. The caller throttles.
  #
  #   result = Catalog::LazyAdd.call("darknet diaries")
  #   result.found # podcasts already in the catalog
  #   result.added # podcasts this call created (pending until their ingest finishes)
  class LazyAdd
    Result = Data.define(:found, :added) do
      def podcasts = found + added
    end

    def self.call(query) = new(query).call

    def initialize(query)
      @query = query.to_s.strip
    end

    def call = Result.new(found: [], added: [])
  end
end
