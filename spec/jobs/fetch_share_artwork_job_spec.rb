require "rails_helper"

# The kit share image's artwork is fetched here, off the request path (R98), under one deadline for the whole fetch.
RSpec.describe FetchShareArtworkJob do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:url) { "https://cdn.example.com/art.jpg" }
  let(:show) { create(:show, artwork_url: url) }
  let(:jpeg) { Vips::Image.black(300, 300).new_from_image([ 0, 128, 128 ]).jpegsave_buffer }

  before do
    allow(Rails).to receive(:cache).and_return(cache)
    allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ])
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  context "for a show with a public kit" do
    before { create(:media_kit, :published, show: show) }

    it "stores the artwork, cropped square, for the share image to read" do
      stub_request(:get, url).to_return(status: 200, body: jpeg)
      described_class.perform_now(show.id)

      stored = ShareImages::ArtworkStore.read(url)
      expect([ stored.width, stored.height, stored.bands ]).to eq([ 240, 240, 4 ])
    end

    it "fetches nothing when the artwork is already stored" do
      ShareImages::ArtworkStore.write(url, Vips::Image.black(240, 240, bands: 4).pngsave_buffer)
      described_class.perform_now(show.id)

      expect(a_request(:get, url)).not_to have_been_made
    end

    it "stores nothing when the fetch fails" do
      stub_request(:get, url).to_return(status: 500)
      described_class.perform_now(show.id)

      expect(ShareImages::ArtworkStore.read(url)).to be_nil
    end

    describe "one deadline for the whole fetch" do
      before { stub_const("ShareImages::Artwork::TOTAL_TIMEOUT", 0.5) }

      # Three hops of 0.3 s each, then the picture: within MAX_REDIRECTS, and each hop well inside the deadline, so
      # per-hop timeouts alone would follow the whole chain (0.9 s) and store the picture.
      it "gives up on a redirect chain whose hops each fit the deadline but together don't" do
        hops = Array.new(2) { |i| "https://cdn.example.com/hop-#{i}.jpg" }
        picture = "https://cdn.example.com/final.jpg"
        [ url, *hops ].zip([ *hops, picture ]).each do |from, to|
          stub_request(:get, from).to_return { sleep 0.3; { status: 302, headers: { "Location" => to } } }
        end
        stub_request(:get, picture).to_return(status: 200, body: jpeg)

        expect(elapsed { described_class.perform_now(show.id) }).to be < 0.8
        expect(a_request(:get, picture)).not_to have_been_made
        expect(ShareImages::ArtworkStore.read(url)).to be_nil
      end

      it "gives up on a server that is slow to send its headers" do
        stub_request(:get, url).to_return { sleep 5; { status: 200, body: jpeg } }

        expect(elapsed { described_class.perform_now(show.id) }).to be < 1.5
        expect(ShareImages::ArtworkStore.read(url)).to be_nil
      end
    end
  end

  it "fetches nothing for a show without a public kit, or without artwork" do
    described_class.perform_now(show.id)
    create(:media_kit, :published, show: create(:show, artwork_url: nil)).then { |kit| described_class.perform_now(kit.show_id) }
    described_class.perform_now(0)

    expect(a_request(:any, /.*/)).not_to have_been_made
  end

  describe "is queued" do
    it "when a kit is published" do
      kit = create(:media_kit, show: show)
      show.verify!

      expect { kit.publish! }.to have_enqueued_job(described_class).with(show.id)
    end

    it "when a public kit's show changes its artwork, and not for other edits" do
      create(:media_kit, :published, show: show)

      expect { show.update!(artwork_url: "https://cdn.example.com/new.jpg") }.to have_enqueued_job(described_class).with(show.id)
      expect { show.update!(title: "Renamed") }.not_to have_enqueued_job(described_class)
    end

    it "once per URL in ten minutes when a share image asks for it (debounced)" do
      create(:media_kit, :published, show: show)
      cache.clear # publishing asked already

      expect { 3.times { ShareImages::ArtworkStore.request(show) } }.to have_enqueued_job(described_class).exactly(:once)
      travel(11.minutes) { expect { ShareImages::ArtworkStore.request(show) }.to have_enqueued_job(described_class) }
    end

    it "not when the artwork is already stored" do
      ShareImages::ArtworkStore.write(url, "png")

      expect { ShareImages::ArtworkStore.request(show) }.not_to have_enqueued_job(described_class)
    end
  end
end
