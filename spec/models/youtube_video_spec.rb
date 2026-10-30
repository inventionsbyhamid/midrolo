require "rails_helper"

RSpec.describe YoutubeVideo do
  describe ".parse" do
    it "takes an id, or the id in a watch, share, Shorts, live or embed link" do
      [ "M1droloTour", " M1droloTour\n", "https://www.youtube.com/watch?v=M1droloTour",
        "https://www.youtube.com/watch?feature=share&v=M1droloTour&t=30", "https://youtu.be/M1droloTour?si=x1",
        "https://m.youtube.com/shorts/M1droloTour", "https://youtube.com/live/M1droloTour",
        "https://www.youtube-nocookie.com/embed/M1droloTour?rel=0" ].each do |value|
        expect(described_class.parse(value)&.id).to eq("M1droloTour"), "expected #{value.inspect}"
      end
    end

    it "is nil for blanks and anything else, so no stray value reaches a URL" do
      [ nil, "", " ", "M1droloTou", "M1droloTour1", "M1drolo/our", "https://example.com/watch?v=M1droloTour",
        "https://www.youtube.com/watch?v=M1droloTour1", "javascript:alert(1)", "\"><script>" ].each do |value|
        expect(described_class.parse(value)).to be_nil, "expected #{value.inspect} to be refused"
      end
    end
  end

  it "links to the video on YouTube, and plays it in the privacy-enhanced player" do
    video = described_class.new("M1droloTour")

    expect(video.watch_url).to eq("https://www.youtube.com/watch?v=M1droloTour")
    expect(video.embed_url).to eq("https://www.youtube-nocookie.com/embed/M1droloTour?autoplay=1&rel=0&modestbranding=1")
  end

  describe ".explainer" do
    it "is the home page's video from the setting, a Setting row first, then EXPLAINER_VIDEO_ID, else none" do
      expect(described_class.explainer).to be_nil

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("EXPLAINER_VIDEO_ID").and_return("Env1Video_x")
      expect(described_class.explainer.id).to eq("Env1Video_x")

      AppSettings.set(:explainer_video_id, "M1droloTour")
      expect(described_class.explainer.id).to eq("M1droloTour")

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
