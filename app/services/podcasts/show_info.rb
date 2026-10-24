module Podcasts
  ShowInfo = Data.define(:directory_id, :title, :author, :description, :artwork_url, :feed_url,
                         :categories, :episode_count, :itunes_id, :language)
end
