# A YouTube video, by its id, and the two places it lives: its page on YouTube and YouTube's privacy-enhanced player
# (youtube-nocookie.com), which components/_youtube loads only when the visitor presses play. The home page's "How
# Midrolo works" video is the one in AppSettings explainer_video_id, set in /admin (Admin::SettingsForm).
# Only a well-formed id makes a YoutubeVideo, so the URLs below never carry anything else. An id may start with a dash
# (-UXzujILAoI), which is safe in a URL path and query.
class YoutubeVideo
  # YouTube's video ids: 11 letters, digits, - and _.
  ID = /\A[A-Za-z0-9_-]{11}\z/
  # The id in a watch, share, Shorts, live or embed link.
  LINK = %r{\Ahttps?://(?:(?:www\.|m\.)?youtube(?:-nocookie)?\.com/(?:watch\?(?:\S*&)?v=|embed/|shorts/|live/)|youtu\.be/)
            ([A-Za-z0-9_-]{11})(?:[?&#/]\S*)?\z}x

  attr_reader :id

  # The video an id or a YouTube link names; nil when blank or neither.
  def self.parse(value)
    value = value.to_s.strip
    id = ID.match?(value) ? value : value[LINK, 1]
    new(id) if id
  end

  # The home page's video, or nil while the setting is blank. A value from ENV isn't checked on its way in, so anything
  # that isn't a video counts as blank too.
  def self.explainer = parse(AppSettings.get(:explainer_video_id))

  def initialize(id)
    raise ArgumentError, "not a YouTube video id: #{id.inspect}" unless ID.match?(id.to_s)

    @id = id
  end

  def watch_url = "https://www.youtube.com/watch?v=#{id}"

  # Plays as it loads (the visitor pressed play), in the page rather than full screen on an iPhone, and suggests only
  # this channel's videos at the end. YouTube no longer honours modestbranding or showinfo: the poster is what keeps
  # its branding off the page until play.
  def embed_url = "https://www.youtube-nocookie.com/embed/#{id}?autoplay=1&rel=0&playsinline=1"
end
