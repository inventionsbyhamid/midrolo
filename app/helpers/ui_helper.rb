# Small view helpers behind the shared UI. The look lives in the component
# classes of app/assets/tailwind/application.css (.btn, .badge, .meter, ...),
# so forms can reuse them too: f.submit "Save", class: "btn btn-primary btn-md".
module UiHelper
  BUTTON_VARIANTS = { primary: "btn-primary", secondary: "btn-secondary", ghost: "btn-ghost", danger: "btn-danger" }.freeze
  BUTTON_SIZES = { sm: "btn-sm", md: "btn-md", lg: "btn-lg" }.freeze
  BADGE_TONES = { neutral: "badge-neutral", success: "badge-success", warning: "badge-warning", danger: "badge-danger", accent: "badge-accent" }.freeze
  METER_SEGMENTS = 20

  # A link when href is given, otherwise a <button> (type defaults to "submit", as in HTML;
  # pass type: "button" for buttons that only drive Stimulus).
  def ui_button(label, href = nil, variant: :primary, size: :md, **opts)
    opts[:class] = class_names("btn", BUTTON_VARIANTS.fetch(variant), BUTTON_SIZES.fetch(size), opts[:class])
    href ? link_to(label, href, **opts) : tag.button(label, **{ type: "submit" }.merge(opts))
  end

  def ui_badge(text, tone: :neutral)
    tag.span(text, class: [ "badge", BADGE_TONES.fetch(tone) ])
  end

  # A segmented level meter for a 0..1 value (affinity, fit). Screen readers get a
  # 0-100 meter; sighted users get 20 segments plus the number.
  def ui_meter(value, label:, value_text: nil, show_label: true)
    value = value.to_f.clamp(0.0, 1.0)
    value_text ||= format("%.2f", value)
    lit = (value * METER_SEGMENTS).round

    tag.div(class: "meter", role: "meter", aria: { label: label, valuenow: (value * 100).round, valuemin: 0, valuemax: 100, valuetext: value_text }) do
      segments = Array.new(METER_SEGMENTS) { |i| tag.span(class: [ "meter-seg", { "meter-seg-on" => i < lit } ]) }
      safe_join([
        (tag.span(label, class: "meter-label") if show_label),
        tag.span(safe_join(segments), class: "meter-track", aria: { hidden: true }),
        tag.span(value_text, class: "meter-value")
      ].compact)
    end
  end

  # True when any Fake adapter is active. Task 6 adds DemoMode; until then the flag is config.x.demo_mode.
  def demo_mode?
    defined?(DemoMode) ? DemoMode.active? : Rails.configuration.x.demo_mode.present?
  end

  def page_title
    content_for?(:title) ? safe_join([ content_for(:title), " | ", APP_NAME ]) : SocialMetaHelper::DEFAULT_TITLE
  end
end
