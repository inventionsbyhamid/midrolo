module Llm
  # Generated text a person reads (the report summary, match reasons, the pitch pack) passes through here before it is
  # saved. Prompts ask for plain, dash-free sentences of a set length, but a prompt can't guarantee either.
  #
  #   sanitize    R100: an em or en dash with space around it becomes ", " (". " when the next word is capitalised),
  #               an unspaced one ", ". A dash that starts or ends a line goes, and so does one after punctuation.
  #   clip_words  the length rule's last resort: the first sentence when that fits, else a cut at a word boundary.
  module PlainText
    DASH_RUN = /([ \t ]*)[—–]+([ \t ]*)/
    PUNCTUATED = /[,.;:!?(]\z/
    SENTENCE = /\A.+?[.!?](?=\s|\z)/m
    ELLIPSIS = "…".freeze

    module_function

    def sanitize(text)
      return text unless text.is_a?(String) && text.match?(DASH_RUN)

      text.gsub(DASH_RUN) do
        match = Regexp.last_match
        before = match.pre_match[-1]
        after = match.post_match[0]
        if before.nil? || after.nil? || before == "\n" || after == "\n" then ""
        elsif match.pre_match.match?(PUNCTUATED) then " "
        elsif !(match[1].empty? && match[2].empty?) && after.match?(/\p{Lu}/) then ". "
        else ", "
        end
      end
    end

    def word_count(text) = text.to_s.split.size

    # text with at most max words (and max_chars characters, when given).
    def clip_words(text, max, max_chars: nil)
      text = text.to_s.strip
      return text if fits?(text, max, max_chars)

      sentence = text[SENTENCE]&.strip
      return sentence if sentence && fits?(sentence, max, max_chars)

      cut(text.split.first(max).join(" "), max_chars)
    end

    def fits?(text, max, max_chars) = word_count(text) <= max && (max_chars.nil? || text.length <= max_chars)

    # Ends the cut with an ellipsis, dropping a dangling comma or the like; one long word is cut mid-word.
    def cut(text, max_chars)
      if max_chars && text.length + ELLIPSIS.length > max_chars
        room = max_chars - ELLIPSIS.length
        shorter = text[0, room + 1].sub(/\s+\S*\z/, "")
        text = shorter.length.between?(1, room) ? shorter : text[0, room]
      end
      "#{text.sub(/[\s,;:]+\z/, '')}#{ELLIPSIS}"
    end
    private_class_method :fits?, :cut
  end
end
