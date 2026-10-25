# Draws every raster brand file from the SVGs with libvips (bin/rails brand:build). Run it after changing
# app/assets/images/brand/*.svg or app/assets/images/og.svg, and commit what it writes:
#   public/icon.svg                 the app icon: mark-dark.svg on an ink tile (a 32-unit grid; at 16px every bar is
#                                   one whole pixel)
#   public/favicon.ico              that tile at 16 and 32px, as PNGs inside the ICO
#   public/apple-touch-icon.png     180px, square and opaque (iOS rounds the corners itself)
#   public/icon-192.png, -512.png   for site.webmanifest
#   app/assets/images/brand/logo-email.png   logo.svg 56px tall (2x for 28) on the mail layout's paper colour
#   app/assets/images/og.png        the landing page's share image, from og.svg (its text needs vendor/fonts)
class BrandBuild
  INK = "#22132b".freeze
  INK_RGB = [ 34, 19, 43 ].freeze
  PAPER_RGB = [ 246, 242, 244 ].freeze
  EMAIL_HEIGHT = 56

  def self.call(...) = new(...).call

  # out: where the files go (the app's root, or a scratch directory in specs).
  def initialize(out: Rails.root)
    @out = Pathname(out)
    @source = Rails.root.join("app/assets/images")
  end

  def call
    write("public/icon.svg", tile)
    { "public/icon-192.png" => 192, "public/icon-512.png" => 512 }.each { |path, size| write(path, png(tile(size))) }
    write("public/apple-touch-icon.png", png(tile(180, rounded: false), background: INK_RGB))
    write("public/favicon.ico", ico([ 16, 32 ].to_h { |size| [ size, png(tile(size)) ] }))
    write("app/assets/images/brand/logo-email.png", png(sized(read("brand/logo.svg"), height: EMAIL_HEIGHT), background: PAPER_RGB))
    write("app/assets/images/og.png", png(read("og.svg"), background: PAPER_RGB))
  end

  private

  # The mark, light on an ink square: rounded for favicons, square where the platform rounds it.
  def tile(size = nil, rounded: true)
    mark = Nokogiri::XML(read("brand/mark-dark.svg"), &:noblanks).root.element_children.reject { |node| node.name == "title" }
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"#{%( width="#{size}" height="#{size}") if size}>
        <title>Midrolo</title>
        <rect width="32" height="32"#{' rx="7"' if rounded} fill="#{INK}"/>
        <svg x="4" y="4" width="24" height="24" viewBox="0 0 24 24">
          #{mark.map { |node| node.to_xml(indent: 2) }.join("\n").gsub("\n", "\n    ")}
        </svg>
      </svg>
    SVG
  end

  def sized(svg, height:)
    root = Nokogiri::XML(svg).root
    _, _, width, box_height = root["viewBox"].split.map(&:to_f)
    root["height"] = height.to_s
    root["width"] = (height * width / box_height).round.to_s
    root.to_xml
  end

  # background flattens the alpha away (an opaque PNG).
  def png(svg, background: nil)
    image = ShareImages::Renderer.load_svg(svg)
    image = image.flatten(background: background) if background
    image.write_to_buffer(".png")
  end

  # An ICO holding PNGs (every browser since IE 11 reads them): a header, a directory entry per size, then the images.
  def ico(pngs)
    offset = 6 + 16 * pngs.size
    entries = pngs.map do |size, data|
      [ size, size, 0, 0, 1, 32, data.bytesize, offset ].pack("CCCCvvVV").tap { offset += data.bytesize }
    end
    [ 0, 1, pngs.size ].pack("v3") + entries.join + pngs.values.join
  end

  def read(name) = @source.join(name).read

  def write(path, content)
    target = @out.join(path)
    target.dirname.mkpath
    target.binwrite(content)
  end
end
