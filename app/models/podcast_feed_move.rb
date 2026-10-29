# A podcast's feed URL moving for good, as Catalog::Ingest found it: a chain of permanent redirects ("redirect") or the
# feed's itunes:new-feed-url ("new_feed_url"). released_show is the owner show whose claim the move released
# (Catalog::FeedMove), nil when the podcast wasn't claimed.
class PodcastFeedMove < ApplicationRecord
  VIA = %w[redirect new_feed_url].freeze

  belongs_to :podcast
  belongs_to :released_show, class_name: "Show", optional: true

  enum :via, VIA.index_with(&:itself), validate: true

  validates :from_url, :to_url, presence: true
end
