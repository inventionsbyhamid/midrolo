# Lighthouse-style checks for system specs, run in the browser on the page as rendered: horizontal overflow, heading
# order, image alt text, text contrast (WCAG AA) and the focus ring.
module PageChecks
  # Pixels the page scrolls sideways (0 when it fits the window).
  def horizontal_overflow = evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")

  # The levels of the visible headings, in document order: [1, 2, 3, 2, ...].
  def heading_levels
    evaluate_script(<<~JS)
      [...document.querySelectorAll("h1, h2, h3, h4, h5, h6")]
        .filter((h) => h.getClientRects().length > 0)
        .map((h) => Number(h.tagName[1]))
    JS
  end

  # Headings that skip a level on the way down (an h2 followed by an h4).
  def skipped_heading_levels
    heading_levels.each_cons(2).filter_map { |a, b| "h#{a} → h#{b}" if b > a + 1 }
  end

  # <img> tags without an alt attribute (alt="" is fine: it marks a decorative image), and <svg>s a screen reader
  # would meet with nothing to say.
  def unlabelled_images
    evaluate_script(<<~JS)
      [...document.querySelectorAll("img:not([alt])"), ...document.querySelectorAll("svg:not([aria-hidden='true'])")]
        .filter((el) => !el.closest("[aria-hidden='true']"))
        .filter((el) => el.tagName === "IMG" || !(el.getAttribute("aria-label") || el.querySelector("title")))
        .map((el) => el.outerHTML.slice(0, 80))
    JS
  end

  # Visible text whose color is under WCAG AA against its background: 4.5:1, or 3:1 for large text (24px, or 18.66px
  # bold). Backgrounds are the nearest opaque background-color up the tree; text on an image or a gradient isn't
  # checked, and nor is a color the browser doesn't report as rgb().
  def contrast_failures
    evaluate_script(<<~JS)
      (() => {
        const parse = (value) => {
          const m = value.match(/^rgba?\\(([^)]+)\\)$/);
          if (!m) return null;
          const [r, g, b, a = 1] = m[1].split(/[\\s,\\/]+/).filter(Boolean).map(Number);
          return { r, g, b, a };
        };
        const channel = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; };
        const luminance = ({ r, g, b }) => 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
        const background = (el) => {
          for (let node = el; node; node = node.parentElement) {
            const style = getComputedStyle(node);
            if (style.backgroundImage !== "none") return null;
            const color = parse(style.backgroundColor);
            if (color && color.a >= 0.99) return color;
          }
          return { r: 255, g: 255, b: 255, a: 1 };
        };
        const failures = [];
        for (const el of document.body.querySelectorAll("*")) {
          const text = [...el.childNodes].filter((n) => n.nodeType === 3).map((n) => n.textContent).join("").trim();
          if (!text || el.getClientRects().length === 0 || el.closest("[aria-hidden='true'], .sr-only")) continue;
          const style = getComputedStyle(el);
          if (style.visibility === "hidden") continue;
          const fg = parse(style.color);
          const bg = background(el);
          if (!fg || !bg) continue;
          const mixed = { r: fg.r * fg.a + bg.r * (1 - fg.a), g: fg.g * fg.a + bg.g * (1 - fg.a), b: fg.b * fg.a + bg.b * (1 - fg.a) };
          const [hi, lo] = [luminance(mixed), luminance(bg)].sort((x, y) => y - x);
          const ratio = (hi + 0.05) / (lo + 0.05);
          const size = parseFloat(style.fontSize);
          const large = size >= 24 || (Number(style.fontWeight) >= 700 && size >= 18.66);
          if (ratio < (large ? 3 : 4.5)) failures.push(`${ratio.toFixed(2)}:1 ${el.tagName.toLowerCase()} "${text.slice(0, 40)}"`);
        }
        return failures;
      })()
    JS
  end

  # The focused element's outline style ("solid" when the focus ring shows).
  def focus_outline_style = evaluate_script("getComputedStyle(document.activeElement).outlineStyle")
end

RSpec.configure do |config|
  config.include PageChecks, type: :system
end
