module Catalog
  # What a feed's URLs say about the show: its hosting provider (config/podcast_hosts.yml) and the download measurement
  # prefixes on its episodes (config/measurement_prefixes.yml), OP3 among them. Detection only: nothing is fetched.
  #
  #   Catalog::Detection.unwrap("https://op3.dev/e/dts.podtrac.com/redirect.mp3/traffic.libsyn.com/a.mp3")
  #   # => [["op3", "podtrac"], "https://traffic.libsyn.com/a.mp3"]
  module Detection
    HOSTS_PATH = Rails.root.join("config/podcast_hosts.yml")
    PREFIXES_PATH = Rails.root.join("config/measurement_prefixes.yml")
    # Prefixes chain (OP3 in front of Podtrac in front of Chartable): at most this many come off one URL.
    MAX_PREFIXES = 6

    module_function

    def hosts = @hosts ||= YAML.load_file(HOSTS_PATH).transform_values(&:freeze).freeze

    def prefixes
      @prefixes ||= YAML.load_file(PREFIXES_PATH).to_h do |vendor, entry|
        patterns = Array(entry["patterns"]).map { |pattern| /\A(?:#{pattern})/i }
        [ vendor, entry.merge("patterns" => patterns).freeze ]
      end.freeze
    end

    # The hosting provider's display name ("Libsyn"), or nil for an unknown key.
    def provider_name(key) = hosts.dig(key.to_s, "name")

    # The measurement vendor's display name ("OP3"), or nil for an unknown key.
    def vendor_name(key) = prefixes.dig(key.to_s, "name")

    # The measurement vendors on url, outermost first, and the URL left once their prefixes are off.
    def unwrap(url)
      rest = url.to_s.strip.sub(%r{\Ahttps?:/+}i, "").sub(/\Awww\./i, "")
      vendors = []
      MAX_PREFIXES.times do
        vendor, match = prefix_at_start(rest)
        break unless vendor

        vendors << vendor
        rest = match.post_match.sub(%r{\Ahttps?:/+}i, "").sub(/\Awww\./i, "")
      end
      [ vendors, "https://#{rest}" ]
    end

    # [vendor, MatchData] for the prefix rest starts with, or nil.
    def prefix_at_start(rest)
      prefixes.each do |vendor, entry|
        entry["patterns"].each do |pattern|
          match = pattern.match(rest)
          return [ vendor, match ] if match
        end
      end
      nil
    end

    # Every vendor whose prefix is on any of the URLs, in config order.
    def measurement(urls)
      found = urls.compact.flat_map { |url| unwrap(url).first }.uniq
      prefixes.keys.select { |vendor| found.include?(vendor) }
    end

    # The hosting provider most of the enclosures (prefixes off) are served from, else the feed URL's, else nil.
    def hosting_provider(enclosure_urls, feed_url: nil)
      votes = enclosure_urls.compact.filter_map { |url| provider_for_host(host_of(unwrap(url).last)) }
      votes.tally.max_by { |key, count| [ count, -hosts.keys.index(key) ] }&.first ||
        provider_for_host(host_of(feed_url))
    end

    def provider_for_host(host)
      return nil if host.blank?

      hosts.find { |_key, entry| entry["hosts"].any? { |domain| host == domain || host.end_with?(".#{domain}") } }&.first
    end

    def host_of(url)
      URI.parse(url.to_s.strip).host&.downcase&.delete_suffix(".")
    rescue URI::InvalidURIError
      nil
    end
  end
end
