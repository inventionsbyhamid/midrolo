require "vips"

module ShareImages
  # libvips does the drawing: a Layout's SVG (librsvg, which sets the text with Pango) becomes the PNG, with the show's
  # artwork laid over the frame the layout left for it. Text is measured with vips_text, also Pango, so a measured line
  # is the width it's drawn at. Both find the Archivo cuts in vendor/fonts through fontconfig
  # (config/initializers/fonts.rb).
  module Renderer
    PAPER = [ 246, 242, 244 ].freeze
    WEIGHTS = { 400 => "Regular", 600 => "SemiBold", 800 => "ExtraBold" }.freeze
    # Active Storage blocks libvips's untrusted loaders, the SVG one among them, so no upload reaches librsvg. Our own
    # SVG (written and escaped by Layout) is loaded with that one loader unblocked, under a lock, and blocked again
    # straight after. Nothing untrusted is decoded by format sniffing meanwhile: ShareImages::Artwork picks a JPEG,
    # PNG or WebP loader itself.
    SVG_LOADER = "VipsForeignLoadSvgBuffer".freeze
    SVG_LOCK = Mutex.new

    module_function

    # PNG bytes, RGB. artwork is an RGBA Vips::Image whose top-left corner goes at at: [x, y].
    def png(svg, artwork: nil, at: nil)
      image = load_svg(svg)
      image = image.composite2(artwork, :over, x: at.first, y: at.last) if artwork
      image.flatten(background: PAPER).cast(:uchar).write_to_buffer(".png")
    end

    # The drawn width of content in pixels. Pango reads it as markup, so it's escaped like the SVG text.
    def text_width(content, family:, weight:, size:)
      return 0 if content.blank?

      Vips::Image.text(ERB::Util.html_escape(content), font: "#{family} #{WEIGHTS.fetch(weight)} #{size}", dpi: 72).width
    end

    # Rendered into memory while the loader is open: libvips loads lazily.
    def load_svg(svg)
      SVG_LOCK.synchronize do
        Vips.block(SVG_LOADER, false)
        Vips::Image.svgload_buffer(svg).copy_memory
      ensure
        Vips.block(SVG_LOADER, true)
      end
    end
  end
end
