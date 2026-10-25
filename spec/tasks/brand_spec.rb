require "rails_helper"

# bin/rails brand:build (BrandBuild): every raster brand file, drawn from the SVGs.
RSpec.describe BrandBuild do
  it "draws the favicon set, the email logo and og.png from the SVGs" do
    Dir.mktmpdir do |dir|
      described_class.call(out: dir)
      size = ->(path) { Vips::Image.new_from_file(File.join(dir, path)).then { |image| [ image.width, image.height ] } }

      expect(size.("public/icon-192.png")).to eq([ 192, 192 ])
      expect(size.("public/icon-512.png")).to eq([ 512, 512 ])
      expect(size.("public/apple-touch-icon.png")).to eq([ 180, 180 ])
      expect(size.("app/assets/images/brand/logo-email.png")).to eq([ 272, 56 ])
      expect(size.("app/assets/images/og.png")).to eq([ 1200, 630 ])
      expect(File.binread(File.join(dir, "public/favicon.ico"))[0, 6].unpack("v3")).to eq([ 0, 1, 2 ])
      expect(File.read(File.join(dir, "public/icon.svg"))).to eq(Rails.root.join("public/icon.svg").read)
    end
  end
end
