require "rails_helper"

# The brand files (app/assets/images/brand) and the favicon set built from them by bin/rails brand:build.
RSpec.describe "Brand assets" do
  def public_file(name) = Rails.root.join("public", name)
  def size(path) = Vips::Image.new_from_file(path.to_s).then { |image| [ image.width, image.height ] }

  describe "the logo files" do
    %w[logo logo-dark mark mark-dark].each do |name|
      it "#{name}.svg is self-contained: a viewBox and a title, shapes only, no text, raster or outside reference" do
        svg = Nokogiri::XML(Rails.root.join("app/assets/images/brand/#{name}.svg").read) { |config| config.strict }
        root = svg.root

        expect(root.name).to eq("svg")
        expect(root["viewBox"]).to match(/\A0 0 [\d.]+ 24\z/)
        expect(root.at_xpath("./*[local-name()='title']").text).to eq("Midrolo")
        expect(svg.xpath("//*[local-name()='text' or local-name()='image' or local-name()='style' or local-name()='use']")).to be_empty
        expect(svg.to_xml).not_to match(/href|url\(|@import|font-family/)
      end
    end
  end

  # Task 20 audit: Rails' stock 400 and 406 pages had no favicon, no brand and its copy.
  it "gives every static error page the favicon, a title naming the app, and a way home" do
    Dir[Rails.root.join("public/*.html")].each do |path|
      page = Nokogiri::HTML(File.read(path))
      name = File.basename(path)

      expect(page.at_css("link[rel='icon']")).to be_present, "#{name} has no favicon"
      expect(page.at_css("title").text).to end_with("| Midrolo"), "#{name}'s title doesn't name the app"
      expect(page.at_css("main a[href='/']")).to be_present, "#{name} has no way home"
    end
  end

  describe "site.webmanifest" do
    let(:manifest) { JSON.parse(public_file("site.webmanifest").read) }

    it "is valid JSON with the name, colours and icons" do
      expect(manifest).to include("name" => "Midrolo", "short_name" => "Midrolo", "start_url" => "/",
                                  "theme_color" => "#22132b", "background_color" => "#f6f2f4")
      expect(manifest["icons"].map { |icon| icon["sizes"] }).to eq(%w[192x192 512x512])
      expect(manifest.values_at("name", "short_name", "description").join(" ")).not_to match(/[\u2013\u2014]/)
    end

    it "is the only web manifest" do
      expect(Rails.root.join("app/views/pwa/manifest.json.erb")).not_to exist
    end

    it "lists icons that exist at the sizes it gives" do
      manifest["icons"].each do |icon|
        path = public_file(icon["src"].delete_prefix("/"))

        expect(path).to exist
        expect(icon["type"]).to eq("image/png")
        expect(size(path).join("x")).to eq(icon["sizes"])
      end
    end
  end

  it "has an opaque 180px apple-touch-icon" do
    image = Vips::Image.new_from_file(public_file("apple-touch-icon.png").to_s)

    expect([ image.width, image.height ]).to eq([ 180, 180 ])
    expect(image.has_alpha? ? image.extract_band(image.bands - 1).min : 255).to eq(255)
  end

  it "has a favicon.ico holding 16 and 32 pixel PNGs" do
    ico = public_file("favicon.ico").binread
    reserved, type, count = ico.unpack("v3")
    sizes = Array.new(count) do |i|
      width, _height, _colours, _reserved, _planes, _bits, length, offset = ico[6 + i * 16, 16].unpack("CCCCvvVV")
      expect(ico[offset, 8].b).to eq("\x89PNG\r\n\x1A\n".b)
      expect(Vips::Image.new_from_buffer(ico[offset, length], "").width).to eq(width)
      width
    end

    expect([ reserved, type ]).to eq([ 0, 1 ])
    expect(sizes).to eq([ 16, 32 ])
  end

  it "has an SVG favicon, and a PNG email logo with the logo's proportions" do
    expect(Nokogiri::XML(public_file("icon.svg").read) { |config| config.strict }.root["viewBox"]).to eq("0 0 32 32")
    width, height = size(Rails.root.join("app/assets/images/brand/logo-email.png"))

    expect(height).to eq(56)
    expect(width).to be_within(1).of(56 * Brand::LOGO_RATIO)
  end

  it "has a landing share image of 1200x630" do
    expect(size(Rails.root.join("app/assets/images/og.png"))).to eq([ 1200, 630 ])
  end
end
