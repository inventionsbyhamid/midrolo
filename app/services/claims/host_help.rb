module Claims
  # Where to click at the podcast's host to prove the show is yours: where its show description is edited (for the
  # feed token) and how to put the owner email in the feed for a while (for the emailed code). Hosts are keyed as
  # podcasts.hosting_provider stores them (config/podcast_hosts.yml, lane L1); before ingest has detected one, the feed
  # URL's own host decides. Hosts without notes here get the general steps.
  class HostHelp
    Entry = Data.define(:key, :name, :description_steps, :email_steps, :wait) do
      def known? = key.present?
    end

    HOSTS = {
      "spotify" => {
        name: "Spotify for Creators",
        feed_hosts: %w[anchor.fm podcasters.spotify.com creators.spotify.com],
        description_steps: [
          "Open Spotify for Creators at creators.spotify.com and pick your show.",
          "Go to Settings, then your show's details.",
          "Paste the line at the end of your show description, then save."
        ],
        email_steps: [
          "Open Spotify for Creators at creators.spotify.com and pick your show.",
          "Go to Settings, then Availability.",
          "Turn on Add email to RSS feed. It adds the email your Spotify account uses."
        ],
        wait: "Spotify usually updates your feed within 10 minutes."
      },
      "buzzsprout" => {
        name: "Buzzsprout",
        feed_hosts: %w[buzzsprout.com],
        description_steps: [
          "Open Buzzsprout and go to Podcast Settings.",
          "Paste the line at the end of your podcast description, then save."
        ],
        email_steps: [
          "Open Buzzsprout and go to Directories.",
          "Choose Email Verification and add your email to the feed. 48 hours is plenty."
        ],
        wait: "Buzzsprout can take a few minutes to update your feed."
      }
    }.freeze

    GENERAL = {
      name: nil,
      description_steps: [
        "Open your show's settings at your podcast host.",
        "Paste the line anywhere in your show description, then save."
      ],
      email_steps: [
        "Open your show's settings at your podcast host.",
        "Look for the owner email, contact email or iTunes email that goes in your RSS feed, and turn it on."
      ],
      wait: "Hosts can take from 15 minutes to a few hours to update your feed."
    }.freeze

    def self.for(podcast)
      key = podcast.hosting_provider.presence_in(HOSTS.keys) || key_for_feed(podcast.feed_url)
      settings = key ? HOSTS.fetch(key) : GENERAL
      Entry.new(key:, **settings.slice(:name, :description_steps, :email_steps, :wait))
    end

    # The host whose feed address this is (anchor.fm is Spotify for Creators), or nil.
    def self.key_for_feed(url)
      host = URI.parse(url.to_s.strip).host.to_s.downcase
      return nil if host.empty?

      HOSTS.find { |_, settings| settings[:feed_hosts].any? { |name| host == name || host.end_with?(".#{name}") } }&.first
    rescue URI::InvalidURIError
      nil
    end
  end
end
