# The public pages (Task 19): where the landing page's calls to action go, and the hero's episode waveform. Their search
# and share tags come from SocialMetaHelper.
module PagesHelper
  CONTACT_EMAIL = "hello@midrolo.com".freeze
  # The waveform's bars, the lit mid-roll slot (in the SVG's 0..1000 x range) and how tall the bars may grow.
  WAVEFORM_BARS = 100
  MIDROLL_SLOT = (600..680)
  WAVEFORM_HEIGHT = 80

  # "Get my free Snapshot": sign in first, or straight to adding a show.
  def snapshot_start_path = user_signed_in? ? new_show_path : new_user_session_path

  # "See a sample report": the first done sample, or the samples page until there is one.
  def sample_start_path(samples) = samples.first ? sample_path(samples.first.sample_slug) : samples_path

  def contact_mail_to(label = CONTACT_EMAIL, **options) = mail_to(CONTACT_EMAIL, label, **options)

  # An episode's waveform with the mid-roll slot lit: the same bars every render (a fixed pattern, no randomness), so
  # the page caches and the screenshot specs stay stable.
  def episode_waveform
    step = 1000.0 / WAVEFORM_BARS
    bars = Array.new(WAVEFORM_BARS) do |i|
      x = (i * step).round(1)
      next if MIDROLL_SLOT.cover?(x + step / 2)

      height = waveform_bar_height(i)
      tag.rect(x: x, y: ((WAVEFORM_HEIGHT - height) / 2.0).round(1), width: (step * 0.56).round(1), height: height,
               rx: 1.5, class: "waveform-bar")
    end
    slot = tag.rect(x: MIDROLL_SLOT.begin + 4, y: 14, width: MIDROLL_SLOT.size - 9, height: WAVEFORM_HEIGHT - 28, rx: 10,
                    class: "waveform-slot")
    tag.svg(safe_join(bars.compact << slot), viewBox: "0 0 1000 #{WAVEFORM_HEIGHT}", preserveAspectRatio: "none",
                                             class: "waveform", aria: { hidden: true })
  end

  private

  # Speech-like: phrases swell and fade, with a little texture between neighbouring bars.
  def waveform_bar_height(i)
    phrase = Math.sin(i * 0.23).abs * 0.6 + Math.sin(i * 0.071 + 1.3).abs * 0.4
    texture = 0.55 + 0.45 * Math.sin(i * 1.7).abs
    (10 + (WAVEFORM_HEIGHT - 16) * phrase * texture).round(1)
  end
end
