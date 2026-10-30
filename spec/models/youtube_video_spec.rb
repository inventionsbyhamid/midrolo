require "rails_helper"

RSpec.describe YoutubeVideo do
  describe ".parse" do
    it "takes an id, or the id in a watch, share, Shorts, live or embed link, a leading dash and all" do
      [ "-UXzujILAoI", " -UXzujILAoI\n", "https://www.youtube.com/watch?v=-UXzujILAoI",
        "https://www.youtube.com/watch?feature=share&v=-UXzujILAoI&t=30", "https://youtu.be/-UXzujILAoI?si=x1",
        "https://m.youtube.com/shorts/-UXzujILAoI", "https://youtube.com/live/-UXzujILAoI",
        "https://www.youtube-nocookie.com/embed/-UXzujILAoI?rel=0" ].each do |value|
        expect(described_class.parse(value)&.id).to eq("-UXzujILAoI"), "expected #{value.inspect}"
      end
    end

    it "is nil for blanks and anything else, so no stray value reaches a URL" do
      [ nil, "", " ", "M1droloTou", "-UXzujILAoI1", "M1drolo/our", "https://example.com/watch?v=-UXzujILAoI",
        "https://www.youtube.com/watch?v=-UXzujILAoI1", "javascript:alert(1)", "\"><script>" ].each do |value|
        expect(described_class.parse(value)).to be_nil, "expected #{value.inspect} to be refused"
      end
    end
  end

  it "links to the video on YouTube, and plays it in the privacy-enhanced player, inline, with this channel's videos after" do
    video = described_class.new("-UXzujILAoI")

    expect(video.watch_url).to eq("https://www.youtube.com/watch?v=-UXzujILAoI")
    expect(video.embed_url).to eq("https://www.youtube-nocookie.com/embed/-UXzujILAoI?autoplay=1&rel=0&playsinline=1")
  end

  it "is made only from a well-formed id, so nothing else reaches its URLs" do
    [ nil, "", "-UXzujILAo", "-UXzujILAoI ", "a b c d e f", "../../x?y=1", "<-UXzujILA>" ].each do |id|
      expect { described_class.new(id) }.to raise_error(ArgumentError), "expected #{id.inspect} to be refused"
    end
  end

  describe ".explainer" do
    it "is the home page's video from the setting, a Setting row first, then EXPLAINER_VIDEO_ID, else none" do
      expect(described_class.explainer).to be_nil

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("EXPLAINER_VIDEO_ID").and_return("-UXzujILAoI") # not JSON, so read as it is
      expect(described_class.explainer.id).to eq("-UXzujILAoI")

      AppSettings.set(:explainer_video_id, "Row1Video_x")
      expect(described_class.explainer.id).to eq("Row1Video_x")

      AppSettings.set(:explainer_video_id, nil) # cleared in /admin
      expect(described_class.explainer).to be_nil
    end

    it "counts a value that isn't a video, such as a mistyped ENV value, as none" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("EXPLAINER_VIDEO_ID").and_return("not a video")
      expect(described_class.explainer).to be_nil
    end
  end
end
