module Podcasts
  # Vendor-neutral podcast directory. Use Podcasts::Directory.current; never call an adapter's vendor API directly.
  # Adapter interface: #search(term, limit: 10), #find(directory_id), #find_by_feed_url(url).
  module Directory
    class MissingCredentials < StandardError; end
    # The directory service failed (auth, outage, timeout). Distinct from a genuine empty result.
    class Unavailable < StandardError; end

    ENV_VARS = %w[PODCAST_INDEX_KEY PODCAST_INDEX_SECRET].freeze

    class << self
      def current
        @current ||= build
      end

      def reset!
        @current = nil
      end

      def fake?
        current.is_a?(Directories::Fake)
      end

      private

      def build
        key = ENV["PODCAST_INDEX_KEY"].presence
        secret = ENV["PODCAST_INDEX_SECRET"].presence
        return Directories::PodcastIndex.new(key: key, secret: secret) if key && secret
        if Rails.env.production?
          raise MissingCredentials, "Podcast directory is not configured: set #{ENV_VARS.join(' and ')}"
        end

        Directories::Fake.new
      end
    end
  end
end
