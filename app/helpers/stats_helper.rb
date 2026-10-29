# Verified stats on pages (lane L5; its other helpers start with stats_).
module StatsHelper
  # Stub (lane L5 fills it): the badge naming where a number came from and how far to trust it. reading_or_level is a
  # StatReading or a level from StatReading::TRUST_LEVELS; source: and at: name the source and its date.
  def trust_badge(reading_or_level, source: nil, at: nil)
    level = reading_or_level.respond_to?(:trust) ? reading_or_level.trust : reading_or_level.to_s
    ui_badge(level.humanize)
  end
end
