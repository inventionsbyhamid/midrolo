class AddWebsiteToShows < ActiveRecord::Migration[8.1]
  def change
    # The channel <link> from the feed: the media kit's fallback contact link.
    add_column :shows, :website, :string
  end
end
