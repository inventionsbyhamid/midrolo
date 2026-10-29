# A show's media kit: the owner's story, photos and rates on top of the show's stats and audience profile
# (assembled by MediaKit::Content), and the podcast's listing. The private preview is always available; the public page
# at /k/:slug (the podcast's slug) needs a verified show and published_at.
class MediaKit < ApplicationRecord
  IMAGE_TYPES = %w[image/jpeg image/png image/webp].freeze
  MAX_IMAGE_BYTES = 5.megabytes
  # A small file can still decode to a huge bitmap; variants would then eat the server's memory.
  MAX_IMAGE_SIDE = 8000
  # The libvips loaders for IMAGE_TYPES (jpegload, pngload_buffer, webpload…): the bytes decide, not the declared type.
  IMAGE_LOADERS = /\A(jpeg|png|webp)load/
  RATE_SLOTS = { "midroll" => "Midroll", "preroll" => "Preroll", "postroll" => "Postroll" }.freeze
  HEADLINE_LIMIT = 120
  ABOUT_LIMIT = 2000
  HIDDEN_BRANDS_LIMIT = 100 # reports list 20 brands; this only bounds a crafted request
  # The listing (build spec section 3): who the show is looking for, what it won't take, and which months are open
  # ("2026-11").
  LOOKING_FOR_LIMIT = 500
  EXCLUSIONS_LIMIT = 20
  MONTH = /\A\d{4}-(0[1-9]|1[0-2])\z/
  VERIFY_TO_PUBLISH = "Verify you own this show to publish.".freeze
  # A visitor counts once per kit in this window.
  VIEW_WINDOW = 30.minutes
  VIEW_DIGEST_SALT = "media_kit/view".freeze
  # Crawlers, link-preview fetchers, scripts and headless browsers. A blank user agent counts as a bot too.
  BOT_AGENT = /bot|crawl|spider|slurp|facebookexternalhit|facebookcatalog|slack|embedly|iframely|whatsapp|
               skypeuripreview|bingpreview|vkshare|quora\ link\ preview|outbrain|pinterest|mastodon|
               google-inspectiontool|lighthouse|headless|phantomjs|puppeteer|playwright|selenium|curl|wget|python|
               httpclient|http\.rb|okhttp|go-http-client|axios|node-fetch|java\/|ruby|libwww|feedfetcher/ix

  belongs_to :show
  # Only the contact email can change through the kit form (the controller permits nothing else).
  accepts_nested_attributes_for :show, update_only: true

  # resize_to_limit keeps the whole picture; libvips does the work (production needs it in the image).
  has_one_attached :cover do |attachable|
    attachable.variant :hero, resize_to_limit: [ 2400, 1200 ]
  end
  has_one_attached :host_photo do |attachable|
    attachable.variant :portrait, resize_to_limit: [ 640, 640 ]
  end

  attribute :remove_cover, :boolean, default: false
  attribute :remove_host_photo, :boolean, default: false

  validates :headline, length: { maximum: HEADLINE_LIMIT }
  validates :about, length: { maximum: ABOUT_LIMIT }
  validates :looking_for, length: { maximum: LOOKING_FOR_LIMIT }
  validate :open_months_are_months
  validate :images_are_small_web_images
  validate :rates_are_whole_dollars

  before_save :purge_removed_images
  # The share image (/k/:slug/og.png) draws the show's artwork from storage, fetched off the request path.
  after_commit :request_share_artwork, if: -> { saved_change_to_published_at? && published? }

  def self.bot?(user_agent) = user_agent.blank? || user_agent.match?(BOT_AGENT)

  # Why a photo can't be used, from its declared type and size, or nil. DirectUploadsController asks before signing an
  # upload, and the validation asks again when the photo is attached.
  def self.upload_problem(content_type:, byte_size:)
    return "must be a JPEG, PNG or WebP image" unless IMAGE_TYPES.include?(content_type)

    "must be 5 MB or smaller" unless byte_size.is_a?(Integer) && byte_size.between?(1, MAX_IMAGE_BYTES)
  end

  def published? = published_at.present?

  # Blank figures are dropped (the rate card's suggestion applies); digits become Integers; anything else stays
  # as typed so validation can name it.
  def rate_card_overrides=(value)
    raw = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
    raw = {} unless raw.is_a?(Hash)
    super(raw.stringify_keys.slice(*RATE_SLOTS.keys).filter_map do |slot, figure|
      figure = figure.to_s.strip
      [ slot, figure.match?(/\A\d+\z/) ? figure.to_i : figure ] if figure.present?
    end.to_h)
  end

  def open_months=(value)
    super(Array(value).map { |month| month.to_s.strip }.compact_blank.uniq.sort)
  end

  def exclusions=(value)
    super(Array(value).map { |item| item.to_s.squish.first(HEADLINE_LIMIT) }.compact_blank.uniq.first(EXCLUSIONS_LIMIT))
  end

  def hidden_brand_ids=(value)
    super(Array(value).map { |id| id.to_s.strip }.compact_blank.uniq.first(HIDDEN_BRANDS_LIMIT))
  end

  def publish!
    unless show.verified?
      errors.add(:base, VERIFY_TO_PUBLISH)
      return false
    end

    update!(published_at: published_at || Time.current)
    true
  end

  def unpublish! = update!(published_at: nil)

  # Counts one view of the public page, atomically. The owner and bots don't count, and a visitor counts once per
  # VIEW_WINDOW. True when counted.
  def record_view(viewer:, user_agent:, ip:)
    return false if viewer && viewer.id == show.user_id
    return false if self.class.bot?(user_agent)
    return false unless first_view_in_window?(ip, user_agent)

    self.class.update_counters(id, views_count: 1)
    true
  end

  private

  # The cache remembers a visitor by a keyed SHA256 of their IP and user agent, never the IP itself. unless_exist
  # makes the first write win, so parallel requests from one visitor count once.
  def first_view_in_window?(ip, user_agent)
    key = Rails.application.key_generator.generate_key(VIEW_DIGEST_SALT, 32)
    visitor = OpenSSL::HMAC.hexdigest("SHA256", key, "#{ip}|#{user_agent}")
    Rails.cache.write("media_kit_view:#{id}:#{visitor}", true, expires_in: VIEW_WINDOW, unless_exist: true)
  end

  # A photo attached in this save, whether the form sent the file or a direct upload's signed id (R149): first what
  # was declared, then the stored bytes themselves, which must open as a JPEG, PNG or WebP of a sane size.
  def images_are_small_web_images
    { cover: cover, host_photo: host_photo }.each do |name, image|
      next unless image.attached? && attachment_changes.key?(name.to_s)

      problem = self.class.upload_problem(content_type: image.blob.content_type, byte_size: image.blob.byte_size)
      errors.add(name, problem) if problem
      check_image(name) unless errors.key?(name)
    end
  end

  def check_image(name)
    width, height, loader = image_header(name)
    if width.nil? || !loader.to_s.match?(IMAGE_LOADERS)
      errors.add(name, "couldn't be read as an image. Try a JPEG, PNG or WebP file.")
    elsif [ width, height ].max > MAX_IMAGE_SIDE
      errors.add(name, "must be at most #{MAX_IMAGE_SIDE} pixels on each side")
    end
  rescue LoadError => e # no libvips here: skip the check rather than refuse every upload
    Rails.logger.warn("[MediaKit] image check skipped: #{e.message}")
  end

  # [width, height, libvips loader] from the image header only (libvips opens lazily and decodes no pixels), or nil
  # when the file isn't a readable image. A form upload is read from what was attached; a direct upload from storage,
  # where a signed id whose upload never finished has nothing to read.
  def image_header(name)
    require "vips"
    attachable = attachment_changes[name.to_s]&.attachable
    source = attachable.is_a?(Hash) ? attachable[:io] : attachable
    if source.respond_to?(:path) && source.path.present?
      header_of(Vips::Image.new_from_file(source.path.to_s, access: :sequential))
    elsif source.respond_to?(:read)
      source.rewind
      header_of(Vips::Image.new_from_buffer(source.read, "", access: :sequential)).tap { source.rewind }
    elsif (blob = public_send(name).blob)&.persisted?
      blob.open { |file| header_of(Vips::Image.new_from_file(file.path, access: :sequential)) }
    end
  rescue Vips::Error, ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError
    nil
  end

  def header_of(image) = [ image.width, image.height, image.get("vips-loader") ]

  def open_months_are_months
    errors.add(:open_months, "must be calendar months") unless open_months.all? { |month| month.to_s.match?(MONTH) }
  end

  def rates_are_whole_dollars
    rate_card_overrides.each do |slot, figure|
      next if figure.is_a?(Integer) && figure >= 0

      errors.add(:"#{slot}_rate", "must be a whole number of dollars, 0 or more")
    end
  end

  def request_share_artwork = ShareImages::ArtworkStore.request(show)

  def purge_removed_images
    cover.purge_later if remove_cover && cover.attached? && !attachment_changes.key?("cover")
    host_photo.purge_later if remove_host_photo && host_photo.attached? && !attachment_changes.key?("host_photo")
  end
end
