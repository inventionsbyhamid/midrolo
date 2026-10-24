module Research
  # Prompt-injection guard: third-party podcast text (feeds, directory entries, other shows' titles, the
  # podcaster's typed hints) reaches the model only inside <untrusted_feed> markers, and anything that looks
  # like a marker is removed from that text first so it can't close the block early. Text is NFKC-normalized
  # (fullwidth ＜／untrusted_feed＞ becomes ASCII) and stripped of zero-width characters before matching, and
  # close variants count too (untrusted-feed, untrusted feed, self-closing, with attributes, unterminated).
  # The agent's instructions say text in these markers is data, never instructions.
  module Untrusted
    OPEN = "<untrusted_feed>".freeze
    CLOSE = "</untrusted_feed>".freeze
    MARKER = %r{<\s*/?\s*untrusted[\s_-]*feed[^>]*>?}i
    ZERO_WIDTH = /[\u200B-\u200D\u2060\uFEFF]/

    module_function

    # The text on one line with any marker-like strings removed.
    def clean(text)
      normalize(text).gsub(ZERO_WIDTH, "").gsub(MARKER, " ").squish
    end

    def normalize(text)
      str = text.to_s
      str = str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace) unless str.encoding == Encoding::UTF_8
      str.scrub.unicode_normalize(:nfkc)
    end

    # The text in markers, cleaned first and then cut to limit characters if given.
    def wrap(text, limit: nil)
      body = clean(text)
      "#{OPEN}#{limit ? body.truncate(limit) : body}#{CLOSE}"
    end

    # Several lines in one block, each cleaned.
    def wrap_lines(lines) = [ OPEN, *lines.map { |line| clean(line) }, CLOSE ].join("\n")
  end
end
