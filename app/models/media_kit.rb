# A show's media kit: the owner's story, photos and rates on top of the show's stats and audience profile
# (assembled by MediaKit::Content). The private preview is always available; the public page at /k/:slug needs a
# verified show and published_at.
class MediaKit < ApplicationRecord
  IMAGE_TYPES = %w[image/jpeg image/png image/webp].freeze
  MAX_IMAGE_BYTES = 5.megabytes
  RATE_SLOTS = { "midroll" => "Mid-roll", "preroll" => "Pre-roll", "postroll" => "Post-roll" }.freeze
  HEADLINE_LIMIT = 120
  ABOUT_LIMIT = 2000
  HIDDEN_BRANDS_LIMIT = 100 # reports list 20 brands; this only bounds a crafted request
  VERIFY_TO_PUBLISH = "Verify you own this show to publish.".freeze
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
    attachable.variant :share, resize_to_limit: [ 1200, 630 ]
  end
  has_one_attached :host_photo do |attachable|
    attachable.variant :portrait, resize_to_limit: [ 640, 640 ]
  end

  attribute :remove_cover, :boolean, default: false
  attribute :remove_host_photo, :boolean, default: false

  validates :headline, length: { maximum: HEADLINE_LIMIT }
  validates :about, length: { maximum: ABOUT_LIMIT }
  validate :images_are_small_web_images
  validate :rates_are_whole_dollars

  before_save :purge_removed_images

  def self.bot?(user_agent) = user_agent.blank? || user_agent.match?(BOT_AGENT)

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

  def hidden_brand_ids=(value)
    super(Array(value).map { |id| id.to_s.strip }.compact_blank.uniq.first(HIDDEN_BRANDS_LIMIT))
  end

  def publish!
    unless show.verified? && show.slug.present?
      errors.add(:base, VERIFY_TO_PUBLISH)
      return false
    end

    update!(published_at: published_at || Time.current)
    true
  end

  def unpublish! = update!(published_at: nil)

  # Counts one view of the public page, atomically. The owner and bots don't count. True when counted.
  def record_view(viewer:, user_agent:)
    return false if viewer && viewer.id == show.user_id
    return false if self.class.bot?(user_agent)

    self.class.update_counters(id, views_count: 1)
    true
  end

  private

  def images_are_small_web_images
    { cover: cover, host_photo: host_photo }.each do |name, image|
      next unless image.attached? && image.blob.new_record?

      errors.add(name, "must be a JPEG, PNG or WebP image") unless IMAGE_TYPES.include?(image.blob.content_type)
      errors.add(name, "must be 5 MB or smaller") if image.blob.byte_size > MAX_IMAGE_BYTES
    end
  end

  def rates_are_whole_dollars
    rate_card_overrides.each do |slot, figure|
      next if figure.is_a?(Integer) && figure >= 0

      errors.add(:"#{slot}_rate", "must be a whole number of dollars, 0 or more")
    end
  end

  def purge_removed_images
    cover.purge_later if remove_cover && cover.attached? && !attachment_changes.key?("cover")
    host_photo.purge_later if remove_host_photo && host_photo.attached? && !attachment_changes.key?("host_photo")
  end
end
