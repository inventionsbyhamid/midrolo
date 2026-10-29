require "rails_helper"

RSpec.describe Catalog::ArtworkJob do
  let(:url) { "https://img.example.com/tidepool.png" }
  let(:png) { Vips::Image.black(600, 600).new_from_image([ 0, 128, 128 ]).pngsave_buffer }
  let(:podcast) do
    create(:podcast, :active, artwork_url: url, description: "About tide pools.", feed_url: "https://feeds.example.com/t.xml")
  end

  before { allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ]) }

  it "runs on the artwork queue" do
    expect(described_class.new(1).queue_name).to eq("artwork")
  end

  it "stores the picture once by its digest, with its size, links it and makes the podcast indexable" do
    stub_request(:get, url).to_return(status: 200, body: png)
    described_class.perform_now(podcast.id)

    image = podcast.reload.artwork_image
    expect(image.sha256).to eq(Digest::SHA256.hexdigest(png))
    expect([ image.width, image.height, image.content_type, image.source_url ]).to eq([ 600, 600, "image/png", url ])
    expect(image.file).to be_attached
    expect(podcast.indexable).to be(true)
    expect(podcast.artwork_variant(:thumb)).to be_present
  end

  it "reuses the stored image for the same bytes from another podcast, and fetches nothing when it is current" do
    stub_request(:get, url).to_return(status: 200, body: png)
    other = create(:podcast, artwork_url: url)
    described_class.perform_now(podcast.id)
    described_class.perform_now(other.id)

    expect(Image.count).to eq(1)
    expect(other.reload.artwork_image).to eq(podcast.reload.artwork_image)

    described_class.perform_now(podcast.id)
    expect(a_request(:get, url)).to have_been_made.twice
  end

  it "takes up to 15 MB, beyond the share image's 5 MB cap" do
    expect(described_class::MAX_BYTES).to eq(15.megabytes)
    big = png + ("\0".b * 6.megabytes)
    stub_request(:get, url).to_return(status: 200, body: big)
    described_class.perform_now(podcast.id)
    expect(podcast.reload.artwork_image).to be_present

    stub_request(:get, url).to_return(status: 200, body: png + ("\0".b * 16.megabytes))
    fresh = create(:podcast, artwork_url: url)
    described_class.perform_now(fresh.id)
    expect(fresh.reload.artwork_image).to be_nil
  end

  it "stores nothing for an SVG, a non-picture, a picture too large or a failed fetch, keeping what was there" do
    [ %(<svg xmlns="http://www.w3.org/2000/svg"/>), "<html>nope</html>",
      Vips::Image.black(9000, 10).pngsave_buffer ].each do |body|
      stub_request(:get, url).to_return(status: 200, body: body)
      described_class.perform_now(podcast.id)
      expect(podcast.reload.artwork_image).to be_nil
    end

    stub_request(:get, url).to_return(status: 500)
    expect { described_class.perform_now(podcast.id) }.not_to raise_error
    expect(Image.count).to eq(0)
  end

  it "never links a picture that was taken down" do
    stub_request(:get, url).to_return(status: 200, body: png)
    Suppression.create!(kind: "image", value: Digest::SHA256.hexdigest(png))
    described_class.perform_now(podcast.id)
    expect(podcast.reload.artwork_image).to be_nil

    Suppression.delete_all
    create(:image, :with_file, sha256: Digest::SHA256.hexdigest(png), suppressed_at: Time.current)
    described_class.perform_now(podcast.id)
    expect(podcast.reload.artwork_image).to be_nil
  end

  it "never fetches an artwork URL that isn't http(s), nor from an internal address" do
    podcast.update!(artwork_url: "file:///etc/passwd")
    described_class.perform_now(podcast.id)

    podcast.update!(artwork_url: "http://internal.example.com/a.png")
    allow(Resolv).to receive(:getaddresses).with("internal.example.com").and_return([ "127.0.0.1" ])
    described_class.perform_now(podcast.id)
    expect(a_request(:get, "http://internal.example.com/a.png")).not_to have_been_made
    expect(podcast.reload.artwork_image).to be_nil
  end
end
