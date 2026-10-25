module ShareImages
  # Text for a share image's SVG: cleaned of what XML forbids, wrapped or shortened (with an ellipsis) to a measured
  # width, and escaped. Widths come from Renderer.text_width, which sets the text with the fonts the SVG is drawn in.
  # font is { family:, weight:, size: }.
  module Text
    ELLIPSIS = "…".freeze
    # C0 controls (but tab, newline and return), DEL and the two noncharacters XML 1.0 forbids.
    FORBIDDEN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F\uFFFE\uFFFF]/

    module_function

    # One line of plain text, or "" for nothing left.
    def clean(value) = value.to_s.scrub("").gsub(FORBIDDEN, "").squish

    # For element content in the SVG: & < > " ' as entities. Pango reads its markup the same way.
    def escape(content) = ERB::Util.html_escape(content.to_s)

    def fits?(content, font, width) = Renderer.text_width(content, **font) <= width

    # At most max_lines lines of words, each within width; a word wider than a line is broken, and the last line is
    # shortened with an ellipsis when the rest doesn't fit.
    def wrap(content, font, width, max_lines)
      words = content.split
      lines = []
      while words.any?
        if lines.size == max_lines - 1
          lines << shorten(words.join(" "), font, width)
          break
        end
        line = words.shift
        unless fits?(line, font, width)
          cut = longest_prefix(line, font, width)
          words.unshift(line[cut..])
          line = line[0, cut]
        end
        line = "#{line} #{words.shift}" while words.any? && fits?("#{line} #{words.first}", font, width)
        lines << line
      end
      lines
    end

    # content as is when it fits, else cut (at a word if one ends near the cut) and ended with an ellipsis.
    def shorten(content, font, width)
      return content if fits?(content, font, width)

      cut = content[0, longest_prefix(content, font, width, suffix: ELLIPSIS)]
      at_word = cut[/\A.*\S(?=\s)/]
      cut = at_word if at_word && at_word.length > cut.length - 12
      cut.rstrip.sub(/[\s,.;:–—-]+\z/, "") + ELLIPSIS
    end

    # The most leading characters of content that fit in width with suffix after them (at least one).
    def longest_prefix(content, font, width, suffix: "")
      low, high = 1, content.length
      while low < high
        mid = (low + high + 1) / 2
        fits?(content[0, mid] + suffix, font, width) ? low = mid : high = mid - 1
      end
      low
    end
  end
end
