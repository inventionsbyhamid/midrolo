namespace :stats do
  # Saves Midrolo's own platform session from stdin, so a deploy can load it without the cookies ever reaching a
  # command line, a log or the terminal: bin/rails "stats:session[spotify]" < session-file. The file holds JSON
  # ({"sp_dc": "..."}) or KEY=value lines (sp_dc=..., SP_DC=..., or SPOTIFY_SP_DC=...). Prints only which keys it saved.
  desc "Save Midrolo's Spotify or Apple service session from stdin (never printed)"
  task :session, [ :platform ] => :environment do |_task, args|
    platform = args[:platform].to_s
    abort "Usage: bin/rails \"stats:session[spotify|apple]\" < file" unless Stats.platform?(platform)

    input = $stdin.read.to_s
    keys = Stats::PLATFORMS.dig(platform, :session_keys)
    values = begin
      parsed = JSON.parse(input)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      input.each_line.each_with_object({}) do |line, found|
        name, value = line.strip.delete_prefix("export ").split("=", 2)
        next if value.nil?

        key = keys.find { |candidate| name.to_s.downcase.end_with?(candidate) }
        found[key] = value.strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'") if key
      end
    end

    session = Stats::ServiceSessions.save!(platform, values.to_h.transform_keys { |key| key.to_s.downcase })
    saved = JSON.parse(session.credentials).keys
    puts "Saved the #{Stats.service_name(platform)} session (#{saved.join(', ')}). Test it at /admin/service_sessions."
  rescue Stats::ServiceSessions::Invalid => e
    abort e.message
  end

  # Owners who typed downloads per episode before the marketplace: their number becomes the podcast's "provided by
  # the show" reading (build spec section 10). Safe to run again.
  desc "Turn verified owners' typed downloads per episode into provided readings"
  task backfill_provided: :environment do
    count = 0
    Show.where.not(verified_at: nil).where.not(downloads_per_episode: nil).includes(:podcast).find_each do |show|
      next if show.podcast.stat_readings.exists?(metric: StatReading::DOWNLOADS_PER_EPISODE, source: Podcast::Stats::PROVIDED_SOURCE)

      show.podcast.record_provided_downloads!(show.downloads_per_episode)
      count += 1
    end
    puts "Added #{count} provided readings."
  end
end
