require "rails_helper"

RSpec.describe ShareImages::Artwork do
  let(:url) { "https://cdn.example.com/art.jpg" }

  before { allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ]) }

  def jpeg(width = 300, height = 200) = Vips::Image.black(width, height).new_from_image([ 0, 128, 128 ]).jpegsave_buffer

  def stub_art(body = jpeg, status: 200, headers: { "Content-Type" => "image/jpeg" })
    stub_request(:get, url).to_return(status: status, body: body, headers: headers)
  end

  it "fetches the artwork and crops it to a square of the asked size, with an alpha band for rounded corners" do
    stub_art
    image = described_class.fetch(url, size: 264)

    expect([ image.width, image.height, image.bands ]).to eq([ 264, 264, 4 ])
    expect(image.getpoint(132, 132).first(3)).to match([ be_within(4).of(0), be_within(4).of(128), be_within(4).of(128) ])
    expect(image.getpoint(0, 0).last).to eq(0) # the corner is cut away
  end

  it "follows a redirect to another public address" do
    stub_request(:get, url).to_return(status: 302, headers: { "Location" => "https://img.example.net/art.jpg" })
    stub_request(:get, "https://img.example.net/art.jpg").to_return(status: 200, body: jpeg)

    expect(described_class.fetch(url, size: 100).width).to eq(100)
  end

  describe "falls back (nil) without raising" do
    it "for no URL" do
      expect(described_class.fetch(nil, size: 100)).to be_nil
      expect(described_class.fetch(" ", size: 100)).to be_nil
    end

    it "for an internal address, without fetching it" do
      expect(described_class.fetch("http://127.0.0.1/art.jpg", size: 100)).to be_nil
      expect(described_class.fetch("http://169.254.169.254/latest/meta-data", size: 100)).to be_nil
      expect(described_class.fetch("file:///etc/passwd", size: 100)).to be_nil
      expect(a_request(:get, /.*/)).not_to have_been_made
    end

    it "for a redirect to an internal address" do
      stub_request(:get, url).to_return(status: 301, headers: { "Location" => "http://10.0.0.5/art.jpg" })

      expect(described_class.fetch(url, size: 100)).to be_nil
      expect(a_request(:get, "http://10.0.0.5/art.jpg")).not_to have_been_made
    end

    it "for an error status, a timeout or a refused connection" do
      stub_art(status: 404)
      expect(described_class.fetch(url, size: 100)).to be_nil

      stub_request(:get, url).to_timeout
      expect(described_class.fetch(url, size: 100)).to be_nil

      stub_request(:get, url).to_raise(Errno::ECONNREFUSED)
      expect(described_class.fetch(url, size: 100)).to be_nil
    end

    it "for a body over the byte cap" do
      stub_const("#{described_class}::MAX_BYTES", 1_000)
      stub_art(jpeg(800, 800) + ("\0" * 2_000))

      expect(described_class.fetch(url, size: 100)).to be_nil
    end

    it "for something that isn't a JPEG, PNG or WebP picture" do
      stub_art("<html>Not found</html>", headers: { "Content-Type" => "text/html" })
      expect(described_class.fetch(url, size: 100)).to be_nil

      svg = %(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>)
      stub_art(svg, headers: { "Content-Type" => "image/svg+xml" })
      expect(described_class.fetch(url, size: 100)).to be_nil
    end

    it "for a picture too large to decode safely" do
      stub_const("#{described_class}::MAX_SIDE", 200)
      stub_art(jpeg(300, 300))

      expect(described_class.fetch(url, size: 100)).to be_nil
    end
  end
end
