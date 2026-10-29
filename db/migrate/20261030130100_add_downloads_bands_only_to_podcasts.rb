# The owner's "Show my numbers as a range" (media_kits.bands_only), copied onto the podcast by Podcast#refresh_listing!
# with the downloads columns, so directory cards, page titles and structured data show the band without loading the
# owner's kit (code review M3). The podcasts already listed get what refresh_listing! now writes: the owner's choice of
# ranges, and no downloads figure on a podcast nobody has claimed (code review L8).
class AddDownloadsBandsOnlyToPodcasts < ActiveRecord::Migration[8.1]
  def up
    add_column :podcasts, :downloads_bands_only, :boolean, null: false, default: false

    execute <<~SQL.squish
      UPDATE podcasts SET downloads_bands_only = TRUE, updated_at = CURRENT_TIMESTAMP
      FROM shows JOIN media_kits ON media_kits.show_id = shows.id
      WHERE shows.podcast_id = podcasts.id AND shows.verified_at IS NOT NULL AND media_kits.bands_only
        AND podcasts.claimed_at IS NOT NULL AND podcasts.downloads_per_episode IS NOT NULL
    SQL
    execute <<~SQL.squish
      UPDATE podcasts SET downloads_per_episode = NULL, downloads_trust = NULL, updated_at = CURRENT_TIMESTAMP
      WHERE claimed_at IS NULL AND (downloads_per_episode IS NOT NULL OR downloads_trust IS NOT NULL)
    SQL
  end

  def down
    remove_column :podcasts, :downloads_bands_only
  end
end
