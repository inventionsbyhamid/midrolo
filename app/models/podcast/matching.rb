# Podcast: matching with brands and similar shows (fit search, report additions).
# Lanes L6 and L8 add their methods here, and only here (build spec section 10), so lanes don't edit the same model file.
module Podcast::Matching
  extend ActiveSupport::Concern

  # ---- L8: the podcast page's Audience and Qloo similar shows ----

  # The report the podcast page's Audience section and Qloo similar shows read, so a page view never calls Qloo (build
  # spec L8, section 10): the owner's done report, else a public sample's; a full report before a Snapshot; then the
  # newest. nil when there is none. Its show and that show's kit come preloaded (the kit's hidden brands stay hidden).
  def taste_report
    reports = Report.done.joins(:show).where(shows: { podcast_id: id })
    reports.where.not(shows: { verified_at: nil }).or(reports.where(sample_slug: Samples.slugs))
           .preload(show: :media_kit)
           .order(Arel.sql("shows.verified_at IS NULL, reports.kind = 'agent' DESC, reports.finished_at DESC NULLS LAST, reports.id DESC"))
           .first
  end
end
