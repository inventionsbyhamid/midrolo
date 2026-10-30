# Turns what a podcaster picked or pasted into Show attributes, using only Podcasts::Directory.current
# and Podcasts::FeedReader. Raises Podcasts::Directory::Unavailable when the directory is down. read_feed: false answers
# from the directory alone (an Apple link, or a feed URL the directory lists) and never reads a feed it doesn't know.
class ShowLookup
  # Only the final /id<digits> path segment counts, so a slug like /my-id2-show/ can't match.
  APPLE_URL = %r{\Ahttps?://podcasts\.apple\.com/.*/id(\d+)(?:[/?#]|\z)}i
  FEED_ERROR = "We couldn't read that feed. Check the URL, or search for your show by name.".freeze
  NOT_FOUND = "We couldn't find that show. Search for it by name, or paste your RSS feed URL.".freeze
  APPLE_NOT_FOUND = "We couldn't find that Apple Podcasts show. Search for it by name, or paste your RSS feed URL.".freeze
  BLANK = "Pick a show from the results, or paste your RSS feed URL.".freeze

  Result = Data.define(:attributes, :error) do
    def ok? = error.nil?
  end

  def self.call(directory_id: nil, feed_url: nil, read_feed: true) = new(directory_id, feed_url, read_feed).call

  def initialize(directory_id, feed_url, read_feed = true)
    @directory_id = directory_id.to_s.strip.presence
    @feed_url = normalize_url(feed_url)
    @read_feed = read_feed
  end

  def call
    return from_directory(directory.find(@directory_id), NOT_FOUND) if @directory_id
    return failure(BLANK) unless @feed_url
    if (apple = @feed_url.match(APPLE_URL))
      return from_directory(directory.find_by_itunes_id(apple[1]), APPLE_NOT_FOUND)
    end

    from_directory(directory_by_feed_url, nil) || (@read_feed ? from_feed : failure(NOT_FOUND))
  end

  private

  def directory = Podcasts::Directory.current

  # The directory's record for a pasted feed URL. Podcast Index refuses some feeds outright (HTTP 400, raised as
  # Unavailable); when we may read feeds, the feed itself answers instead of the error.
  def directory_by_feed_url
    directory.find_by_feed_url(@feed_url)
  rescue Podcasts::Directory::Unavailable
    raise unless @read_feed

    nil
  end

  def normalize_url(raw)
    url = raw.to_s.strip
    return nil if url.blank?

    url.match?(%r{\A[a-z][a-z0-9+.-]*://}i) ? url : "https://#{url}"
  end

  def from_directory(info, error)
    return (error ? failure(error) : nil) unless info

    Result.new(attributes: {
                 directory_id: info.directory_id, itunes_id: info.itunes_id, feed_url: info.feed_url.presence || @feed_url,
                 title: info.title, author: info.author, description: info.description, artwork_url: info.artwork_url,
                 categories: Array(info.categories), episode_count: info.episode_count, language: info.language
               }, error: nil)
  end

  def from_feed
    feed = Podcasts::FeedReader.new.read(@feed_url, max_episodes: 50)
    return failure(FEED_ERROR) if feed.title.blank?

    Result.new(attributes: {
                 feed_url: @feed_url, title: feed.title, author: feed.owner_name, description: feed.description,
                 owner_email: feed.owner_email, cadence_days: feed.cadence_days, website: Show.http_url(feed.website),
                 episode_count: feed.episodes.size.nonzero?
               }, error: nil)
  end

  def failure(message) = Result.new(attributes: nil, error: message)
end
