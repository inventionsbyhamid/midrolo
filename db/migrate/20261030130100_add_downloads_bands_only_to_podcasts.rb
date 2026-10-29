# The owner's "Show my numbers as a range" (media_kits.bands_only), copied onto the podcast by Podcast#refresh_listing!
# with the downloads columns, so directory cards, page titles and structured data show the band without loading the
# owner's kit (code review M3).
class AddDownloadsBandsOnlyToPodcasts < ActiveRecord::Migration[8.1]
  def change
    add_column :podcasts, :downloads_bands_only, :boolean, null: false, default: false
  end
end
