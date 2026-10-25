require "rails_helper"

RSpec.describe MediaKit do
  let(:user) { create(:user) }
  let(:show) { create(:show, user: user) }
  let(:kit) { described_class.create!(show: show) }

  def fixture(name) = Rails.root.join("spec/fixtures/files", name)

  describe "images" do
    it "accepts JPEG, PNG and WebP host photos and covers" do
      kit.host_photo.attach(io: fixture("host.jpg").open, filename: "host.jpg")
      kit.cover.attach(io: fixture("cover.png").open, filename: "cover.png")

      expect(kit.reload.host_photo).to be_attached
      expect(kit.cover).to be_attached
    end

    it "rejects other types, judged by the file's contents, with a helpful error" do
      svg = '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'
      kit.cover = { io: StringIO.new(svg), filename: "cover.png", content_type: "image/png" }

      expect(kit).not_to be_valid
      expect(kit.errors.full_messages).to include("Cover must be a JPEG, PNG or WebP image")
    end

    it "rejects images over 5 MB" do
      big = "\x89PNG\r\n\x1a\n".b + ("\0" * 5.megabytes)
      kit.host_photo = { io: StringIO.new(big), filename: "big.png" }

      expect(kit).not_to be_valid
      expect(kit.errors.full_messages).to include("Host photo must be 5 MB or smaller")
    end

    describe "dimensions" do
      # A few hundred bytes that would decode to a huge bitmap: only the header is read to reject it.
      def png(width, height) = Vips::Image.black(width, height).pngsave_buffer

      it "rejects an image over 8000 pixels on either side, however small the file" do
        wide = png(8001, 1)
        expect(wide.bytesize).to be < 2.kilobytes
        kit.cover = { io: StringIO.new(wide), filename: "wide.png" }
        expect(kit).not_to be_valid
        expect(kit.errors.full_messages).to include("Cover must be at most 8000 pixels on each side")

        kit.host_photo = { io: StringIO.new(png(1, 9000)), filename: "tall.png" }
        kit.cover = nil
        expect(kit).not_to be_valid
        expect(kit.errors.full_messages).to eq([ "Host photo must be at most 8000 pixels on each side" ])
      end

      it "accepts exactly 8000 pixels, read from an uploaded file's path" do
        Tempfile.create([ "edge", ".png" ], binmode: true) do |file|
          file.write(png(8000, 1))
          file.flush
          kit.cover = Rack::Test::UploadedFile.new(file.path, "image/png")
          expect(kit).to be_valid
        end
      end

      it "rejects a file that claims to be an image but can't be read as one" do
        kit.cover = { io: StringIO.new("\x89PNG\r\n\x1a\n".b + "garbage" * 20), filename: "broken.png" }
        expect(kit).not_to be_valid
        expect(kit.errors.full_messages).to include("Cover couldn't be read as an image. Try a JPEG, PNG or WebP file.")
      end
    end

    it "removes a photo when asked" do
      kit.host_photo.attach(io: fixture("host.jpg").open, filename: "host.jpg")
      kit.update!(remove_host_photo: "1")

      expect(kit.reload.host_photo).not_to be_attached
    end
  end

  describe "rate card overrides" do
    it "keeps whole, non-negative dollar amounts and drops blanks (blank means use the suggestion)" do
      kit.update!(rate_card_overrides: { "midroll" => "150", "preroll" => "", "postroll" => " 40 ", "bogus" => "9" })
      expect(kit.reload.rate_card_overrides).to eq("midroll" => 150, "postroll" => 40)
    end

    it "rejects negatives, decimals and words" do
      %w[-5 12.5 lots].each do |value|
        kit.rate_card_overrides = { "midroll" => value }
        expect(kit).not_to be_valid
        expect(kit.errors.full_messages).to include("Mid-roll rate must be a whole number of dollars, 0 or more")
      end
    end
  end

  it "keeps hidden brand ids as unique strings" do
    kit.update!(hidden_brand_ids: [ "", "brand-1", "brand-1", 42 ])
    expect(kit.reload.hidden_brand_ids).to eq(%w[brand-1 42])
  end

  describe "#publish!" do
    it "refuses an unverified show" do
      expect(kit.publish!).to be(false)
      expect(kit.errors[:base]).to include("Verify you own this show to publish.")
      expect(kit.reload.published_at).to be_nil
    end

    it "publishes once the show is verified" do
      show.verify!
      expect(kit.publish!).to be(true)
      expect(kit.reload).to be_published
    end

    it "unpublishes" do
      show.verify!
      kit.publish!
      kit.unpublish!
      expect(kit.reload).not_to be_published
    end
  end

  describe "#record_view" do
    let(:browser) { "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15" }

    it "counts a visitor's browser" do
      expect(kit.record_view(viewer: nil, user_agent: browser, ip: "203.0.113.7")).to be(true)
      expect(kit.record_view(viewer: create(:user), user_agent: browser, ip: "203.0.113.7")).to be(true)
      expect(kit.reload.views_count).to eq(2)
    end

    it "counts a visitor once per 30 minutes per kit, keyed on a hash of IP and browser, never the raw IP" do
      cache = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(cache)
      other_kit = described_class.create!(show: create(:show))

      expect(kit.record_view(viewer: nil, user_agent: browser, ip: "203.0.113.7")).to be(true)
      expect(kit.record_view(viewer: nil, user_agent: browser, ip: "203.0.113.7")).to be(false)
      expect(kit.record_view(viewer: nil, user_agent: browser, ip: "198.51.100.4")).to be(true) # another visitor
      expect(kit.record_view(viewer: nil, user_agent: "#{browser} Edg/130", ip: "203.0.113.7")).to be(true) # another browser
      expect(other_kit.record_view(viewer: nil, user_agent: browser, ip: "203.0.113.7")).to be(true) # another kit
      travel 31.minutes
      expect(kit.record_view(viewer: nil, user_agent: browser, ip: "203.0.113.7")).to be(true)

      expect(kit.reload.views_count).to eq(4)
      keys = cache.instance_variable_get(:@data).keys.join(" ")
      expect(keys).to include("media_kit_view:#{kit.id}:")
      expect(keys).not_to include("203.0.113.7")
    end

    it "skips the owner" do
      expect(kit.record_view(viewer: user, user_agent: browser, ip: "203.0.113.7")).to be(false)
      expect(kit.reload.views_count).to eq(0)
    end

    [
      "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
      "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)",
      "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
      "Twitterbot/1.0",
      "LinkedInBot/1.0 (compatible; Mozilla/5.0; Apache-HttpClient +http://www.linkedin.com)",
      "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)",
      "WhatsApp/2.23.20.0",
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/120.0.0.0 Safari/537.36",
      "curl/8.4.0",
      "python-requests/2.31.0",
      ""
    ].each do |agent|
      it "skips #{agent.presence || 'a blank user agent'}" do
        expect(kit.record_view(viewer: nil, user_agent: agent, ip: "203.0.113.7")).to be(false)
        expect(kit.reload.views_count).to eq(0)
      end
    end
  end
end
