# /demo/feed.xml: the demo show's RSS feed (lane L4, bin/rails demo:setup), served from its podcast row and episodes,
# so the demo looks like any podcast without a real host behind it. A 404 until demo:setup has run. Never indexed.
class DemoFeedsController < ApplicationController
  EPISODE_LIMIT = 50

  def show
    @podcast = Podcast.demo.first || raise(ActiveRecord::RecordNotFound)
    @episodes = @podcast.episodes.newest_first.limit(EPISODE_LIMIT).to_a
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
    expires_in 10.minutes, public: true
  end

  private

  # Podcast apps and feed readers aren't modern browsers.
  def any_browser? = true
end
