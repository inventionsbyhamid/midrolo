module Llm
  # Generated text a person reads (the report summary, match reasons, the pitch pack) passes through here before it is
  # saved. Prompts ask for plain, dash-free sentences of a set length, but a prompt can't guarantee either.
  #
  #   sanitize    R100 and R100a: a dash between two numbers reads as "to" ("25 to 34"); a pair of dashes inside one
  #               sentence becomes a pair of commas; a single dash with space around it becomes ", " (". " before a
  #               capitalised word), an unspaced one ", ". A dash that starts or ends a line goes, and so does one
  #               after punctuation.
  #   sentences   the text's sentences, never split after an abbreviation ("Dr.", "U.S.").
  #   clip_words  the length rule's last resort: the first sentence when it fits and has a real length, else a cut at
  #               a word boundary.
  module PlainText
    SPACE = "[ \\t\\u00A0]*".freeze
    DASHES = "[\\u2014\\u2013]+".freeze
    DASH = /[—–]/
    DASH_RUN = /(#{SPACE})#{DASHES}(#{SPACE})/
    RANGE = /(\d)#{SPACE}#{DASHES}#{SPACE}(?=\d)/
    # What ends a sentence, for telling which dashes share one.
    SENTENCE_END = /[.!?](?=\s|\z)|\n/
    SENTENCE_BREAK = /(?<=[.!?])\s+/
    # A period that ends an abbreviation ("Dr.", "U.S.", "e.g."), not a sentence.
    ABBREVIATION = /(?:\A|\s)(?:Dr|Mr|Mrs|Ms|Mx|St|Jr|Sr|Mt|Inc|Co|Ltd|vs|etc|e\.g|i\.e|(?:[A-Z]\.)+[A-Z])\.\z/
    PUNCTUATED = /[,.;:!?(]\z/
    MIN_SENTENCE_WORDS = 5
    ELLIPSIS = "…".freeze

    module_function

    def sanitize(text)
      return text unless text.is_a?(String) && text.match?(DASH)

      text = text.gsub(RANGE) { "#{Regexp.last_match(1)} to " }
      in_sentence = Hash.new(0)
      text.to_enum(:scan, DASH_RUN).each { in_sentence[sentence_index(text, Regexp.last_match.begin(0))] += 1 }
      text.gsub(DASH_RUN) do
        match = Regexp.last_match
        replacement(match, paired: in_sentence[sentence_index(text, match.begin(0))] > 1)
      end
    end

    def sentences(text)
      text.to_s.squish.split(SENTENCE_BREAK).each_with_object([]) do |piece, out|
        if out.last&.match?(ABBREVIATION)
          out[-1] = "#{out.last} #{piece}"
        else
          out << piece
        end
      end
    end

    def word_count(text) = text.to_s.split.size

    # text with at most max words (and max_chars characters, when given).
    def clip_words(text, max, max_chars: nil)
      text = text.to_s.strip
      return text if fits?(text, max, max_chars)

      sentence = sentences(text).first
      real = word_count(sentence) >= [ MIN_SENTENCE_WORDS, (max / 3.0).ceil ].min
      return sentence if sentence && real && fits?(sentence, max, max_chars)

      cut(text.split.first(max).join(" "), max_chars)
    end

    def replacement(match, paired:)
      before = match.pre_match[-1]
      after = match.post_match[0]
      spaced = !(match[1].empty? && match[2].empty?)
      if before.nil? || after.nil? || before == "\n" || after == "\n" then ""
      elsif match.pre_match.match?(PUNCTUATED) then " "
      elsif paired then ", "
      elsif spaced && after.match?(/\p{Lu}/) then ". "
      else ", "
      end
    end

    # Which sentence of text the position falls in, counted from 0.
    def sentence_index(text, position) = text[0...position].scan(SENTENCE_END).size

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
    private_class_method :replacement, :sentence_index, :fits?, :cut
  end
end
