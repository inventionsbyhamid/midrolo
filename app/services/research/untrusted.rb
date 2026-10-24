module Research
  # Prompt-injection guard: third-party podcast text (feeds, directory entries, other shows' titles, the
  # podcaster's typed hints) reaches the model only inside <untrusted_feed> markers, and any marker strings
  # inside that text are removed first so it can't close the block early. The agent's instructions say text
  # in these markers is data, never instructions.
  module Untrusted
    OPEN = "<untrusted_feed>".freeze
    CLOSE = "</untrusted_feed>".freeze
    MARKER = %r{<\s*/?\s*untrusted_feed\s*>}i

    module_function

    # The text on one line with any marker strings removed.
    def clean(text) = text.to_s.gsub(MARKER, " ").squish

    # The text in markers, cleaned first and then cut to limit characters if given.
    def wrap(text, limit: nil)
      body = clean(text)
      "#{OPEN}#{limit ? body.truncate(limit) : body}#{CLOSE}"
    end

    # Several lines in one block, each cleaned.
    def wrap_lines(lines) = [ OPEN, *lines.map { |line| clean(line) }, CLOSE ].join("\n")
  end
end
