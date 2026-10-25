# Search and share tags, built in one place so no page writes them by hand. A public page passes social_meta to
# content_for :meta: description, canonical URL, Open Graph and Twitter tags, each once, every URL absolute. Any other
# page gets private_page_meta from layouts/_head: noindex, and no share image.
module SocialMetaHelper
  DEFAULT_TITLE = "#{APP_NAME}: find sponsors who already love your listeners".freeze
  DEFAULT_IMAGE_ALT = "#{APP_NAME}: find sponsors who already love your listeners".freeze
  SHARE_IMAGE_SIZE = { width: 1200, height: 630 }.freeze
  LOCALE = "en_US".freeze

  # title defaults to the page's own (content_for :title), without the site name, which og:site_name carries. image is
  # a 1200x630 picture (a path or URL); the landing page's og.png by default. url is the canonical address: this
  # request's, without the query string, by default.
  def social_meta(description:, title: nil, image: nil, image_alt: DEFAULT_IMAGE_ALT, type: "website", url: nil)
    title ||= content_for?(:title) ? content_for(:title) : DEFAULT_TITLE
    url ||= request.base_url + request.path
    image = URI.join(request.base_url, image || image_path("og.png")).to_s
    safe_join([
      tag.meta(name: "description", content: description),
      tag.link(rel: "canonical", href: url),
      *open_graph(title:, description:, url:, type:, image:, image_alt:),
      *twitter_card(title:, description:, image:, image_alt:)
    ], "\n")
  end

  def private_page_meta = tag.meta(name: "robots", content: "noindex, nofollow")

  private

  def open_graph(title:, description:, url:, type:, image:, image_alt:)
    { "site_name" => APP_NAME, "type" => type, "url" => url, "title" => title, "description" => description,
      "image" => image, "image:width" => SHARE_IMAGE_SIZE[:width], "image:height" => SHARE_IMAGE_SIZE[:height],
      "image:alt" => image_alt, "locale" => LOCALE }.map { |key, value| tag.meta(property: "og:#{key}", content: value) }
  end

  def twitter_card(title:, description:, image:, image_alt:)
    { "card" => "summary_large_image", "title" => title, "description" => description, "image" => image,
      "image:alt" => image_alt }.map { |key, value| tag.meta(name: "twitter:#{key}", content: value) }
  end
end
