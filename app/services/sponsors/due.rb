# Which episodes sponsor detection reads (the user's cost rules, 2026-10-30). Each recent episode gets one model check,
# and model work is never repeated:
#
# - Only episodes the AI-first scan hasn't settled (sponsor_ai_checked_at NULL), so an episode an older pattern-only
#   scan read (sponsor_scanned_at set) still gets its one check.
# - Only episodes published in the last sponsors_ai_window_days (AppSettings, default 30). Older ones are left alone
#   and stay unchecked, so a wider window can reach them later on purpose.
# - Only active podcasts', at most sponsors_max_per_podcast (default 10) of one podcast's in a run, the newest first.
#
# A checked episode is never sent again, except by the deliberate `bin/rails sponsors:rescan[slug]`. Without a model
# (fake LLM mode: development and tests) the pattern scan stands in, once per episode (sponsor_scanned_at NULL).
# Ingest's scan, Sponsors::ScanJob, the daily sweep and `bin/rails sponsors:scan_unscanned` all choose through here.
module Sponsors
  module Due
    WINDOW_DAYS = 30
    MAX_PER_PODCAST = 10

    module_function

    # The episodes in scope (every episode by default) that are due: not checked yet and inside the window (days).
    def episodes(scope = Episode.all, days: window_days)
      scope = scope.where(published_at: days.days.ago..)
      Llm.fake? ? scope.where(sponsor_scanned_at: nil) : scope.where(sponsor_ai_checked_at: nil)
    end

    # One run's share of a podcast's due episodes (scope: its episodes, or some of them), the newest first.
    def for_run(scope) = episodes(scope).newest_first.limit(max_per_podcast)

    # Active podcasts with an episode due.
    def podcasts = Podcast.active.where(id: episodes.select(:podcast_id))

    # Every active podcast's due episodes: what scans still have to read.
    def waiting(days: window_days) = episodes(days: days).where(podcast_id: Podcast.active.select(:id))

    # 0 turns sponsor detection off.
    def window_days = [ setting(:sponsors_ai_window_days, WINDOW_DAYS), 0 ].max

    def max_per_podcast = setting(:sponsors_max_per_podcast, MAX_PER_PODCAST).clamp(1, ScanJob::MAX_EPISODES)

    def setting(key, default) = Integer(AppSettings.get(key, default: default).to_s, exception: false) || default
  end
end
