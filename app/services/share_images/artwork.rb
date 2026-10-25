require "timeout"

module ShareImages
  # A show's artwork for its kit's share image, fetched by FetchShareArtworkJob, never on a request (R98). It is fetched
  # the way Podcasts::FeedReader fetches a feed: Podcasts::SafeUrl checks every hop (http(s) on 80/443, no internal
  # address) and pins it to the address it checked (R131), and the body streams under a byte cap. One deadline covers the whole fetch, redirects included: each hop's
  # open and read timeouts come from what is left of it, and a hard wall-clock timeout around everything also bounds
  # what those can't (DNS in SafeUrl, a server that drips its headers). Only a JPEG, PNG or WebP of sane dimensions is
  # decoded. It comes back as PNG bytes, cropped to a square with rounded corners; anything else is nil, never an error.
  module Artwork
    MAX_BYTES = 5.megabytes
    MAX_SIDE = MediaKit::MAX_IMAGE_SIDE
    TOTAL_TIMEOUT = 8 # seconds, for the whole fetch
    OPEN_TIMEOUT = 3
    MAX_REDIRECTS = 3
    REDIRECTS = [ 301, 302, 303, 307, 308 ].freeze
    # The loader for each accepted format, by its first bytes, checked before libvips sees them: an SVG or anything
    # else libvips could sniff never reaches a decoder.
    LOADERS = { /\A\xFF\xD8\xFF/n => :jpegload_buffer, /\A\x89PNG\r\n\x1A\n/n => :pngload_buffer,
                /\ARIFF.{4}WEBP/mn => :webpload_buffer }.freeze

    class TooLarge < StandardError; end
    class TooSlow < StandardError; end

    module_function

    # PNG bytes, size x size, or nil.
    def fetch(url, size:)
      deadline = now + TOTAL_TIMEOUT
      bytes = Timeout.timeout(TOTAL_TIMEOUT, TooSlow) { download(url.to_s.strip, deadline) }
      bytes && picture(bytes, size)
    rescue StandardError => e
      Rails.logger.info("[ShareImages::Artwork] no artwork: #{e.class}: #{e.message}")
      nil
    end

    def download(url, deadline)
      return if url.empty?

      (MAX_REDIRECTS + 1).times do
        target = Podcasts::SafeUrl.resolve!(url)
        response, body = get(target, deadline)
        return body if response.status == 200
        return unless REDIRECTS.include?(response.status)

        url = URI.join(url, response.headers["location"].to_s).to_s
      end
      nil
    end

    # One hop, with timeouts from what's left of the deadline. The body is checked against the cap and the deadline
    # as it streams.
    def get(target, deadline)
      left = deadline - now
      raise TooSlow, "over #{TOTAL_TIMEOUT}s" unless left.positive?

      body = +"".b
      response = connection(left, target).get(target.uri.to_s) do |request|
        request.options.on_data = proc do |chunk, received|
          raise TooLarge, "over #{MAX_BYTES} bytes" if received > MAX_BYTES
          raise TooSlow, "over #{TOTAL_TIMEOUT}s" if now > deadline

          body << chunk
        end
      end
      [ response, body ]
    end

    # The header is read lazily, so a picture's size is checked before any pixels are decoded; thumbnail_buffer then
    # shrinks while it decodes.
    def picture(bytes, size)
      loader = LOADERS.find { |magic, _| bytes.match?(magic) }&.last
      return unless loader

      header = Vips::Image.public_send(loader, bytes)
      return if [ header.width, header.height ].max > MAX_SIDE

      square = Vips::Image.thumbnail_buffer(bytes, size, height: size, crop: :centre).colourspace(:srgb).cast(:uchar)
      square = square.flatten(background: 255) if square.has_alpha?
      square.bandjoin(corner_mask(size)).write_to_buffer(".png")
    end

    def corner_mask(size)
      svg = %(<svg xmlns="http://www.w3.org/2000/svg" width="#{size}" height="#{size}">) +
            %(<rect width="#{size}" height="#{size}" rx="#{Layout::ARTWORK_RADIUS}" fill="#fff"/></svg>)
      Renderer.load_svg(svg).extract_band(3)
    end

    # One per hop: it reaches only that hop's vetted address.
    def connection(left, target)
      Faraday.new(headers: { "User-Agent" => Podcasts::FeedReader::USER_AGENT, "Accept" => "image/*" }) do |faraday|
        faraday.options.timeout = left
        faraday.options.open_timeout = [ OPEN_TIMEOUT, left ].min
        Podcasts::SafeUrl.pin(faraday, target)
      end
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
