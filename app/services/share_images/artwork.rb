module ShareImages
  # A show's artwork for its kit's share image, fetched the way Podcasts::FeedReader fetches a feed: Podcasts::SafeUrl
  # checks every hop (http(s) on 80/443, no internal address), and the body streams under a byte cap and one deadline
  # for the whole download. Only a JPEG, PNG or WebP of sane dimensions is decoded; it comes back cropped to a square
  # with rounded corners. Anything else is nil, never an error, and the card draws the mark instead.
  module Artwork
    MAX_BYTES = 5.megabytes
    MAX_SIDE = MediaKit::MAX_IMAGE_SIDE
    TIMEOUT = 5
    OPEN_TIMEOUT = 3
    MAX_REDIRECTS = 3
    REDIRECTS = [ 301, 302, 303, 307, 308 ].freeze
    # The loader for each accepted format, by its first bytes, checked before libvips sees them: an SVG or anything
    # else libvips could sniff never reaches a decoder.
    LOADERS = { /\A\xFF\xD8\xFF/n => :jpegload_buffer, /\A\x89PNG\r\n\x1A\n/n => :pngload_buffer,
                /\ARIFF.{4}WEBP/mn => :webpload_buffer }.freeze

    class TooLarge < StandardError; end

    module_function

    # An RGBA Vips::Image, size x size, or nil.
    def fetch(url, size:)
      bytes = download(url.to_s.strip)
      bytes && picture(bytes, size)
    rescue StandardError => e
      Rails.logger.info("[ShareImages::Artwork] no artwork: #{e.class}: #{e.message}")
      nil
    end

    def download(url)
      return if url.empty?

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT
      (MAX_REDIRECTS + 1).times do
        Podcasts::SafeUrl.check!(url)
        response, body = get(url, deadline)
        return body if response.status == 200
        return unless REDIRECTS.include?(response.status)

        url = URI.join(url, response.headers["location"].to_s).to_s
      end
      nil
    end

    def get(url, deadline)
      body = +"".b
      response = connection.get(url) do |request|
        request.options.on_data = proc do |chunk, received|
          raise TooLarge, "over #{MAX_BYTES} bytes" if received > MAX_BYTES
          raise Faraday::TimeoutError, "over #{TIMEOUT}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

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
      square.bandjoin(corner_mask(size))
    end

    def corner_mask(size)
      svg = %(<svg xmlns="http://www.w3.org/2000/svg" width="#{size}" height="#{size}">) +
            %(<rect width="#{size}" height="#{size}" rx="#{Layout::ARTWORK_RADIUS}" fill="#fff"/></svg>)
      Renderer.load_svg(svg).extract_band(3)
    end

    def connection
      Faraday.new(headers: { "User-Agent" => Podcasts::FeedReader::USER_AGENT, "Accept" => "image/*" }) do |faraday|
        faraday.options.timeout = TIMEOUT
        faraday.options.open_timeout = OPEN_TIMEOUT
        faraday.adapter Faraday.default_adapter
      end
    end
  end
end
