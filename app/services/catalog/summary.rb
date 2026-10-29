module Catalog
  # What the admin dashboard's catalog panel shows: podcasts by status, how many are indexable, claimed, linked to Qloo,
  # due for a feed read and never read, how many episodes are stored, and the latest feed errors.
  module Summary
    ERRORS_SHOWN = 10

    Counts = Data.define(:by_status, :total, :indexable, :claimed, :qloo_linked, :due, :never_read, :episodes, :errors)

    module_function

    def call(now: Time.current)
      by_status = Podcast.group(:status).count
      Counts.new(
        by_status: Podcast::STATUSES.index_with { |status| by_status.fetch(status, 0) }, total: by_status.values.sum,
        indexable: Podcast.indexable.count, claimed: Podcast.claimed.count,
        qloo_linked: Podcast.where.not(qloo_entity_id: nil).count,
        due: Podcast.where(next_fetch_at: ..now).where.not(status: "removed").count,
        never_read: Podcast.where(feed_checked_at: nil).where.not(status: "removed").count,
        episodes: Episode.count,
        errors: Podcast.where.not(last_error: nil).order(feed_checked_at: :desc, id: :desc).limit(ERRORS_SHOWN)
                       .select(:id, :title, :slug, :status, :last_error, :fetch_failures, :feed_checked_at, :next_fetch_at).to_a
      )
    end
  end
end
