module Research
  # Name comparison for matching what people (and feeds) type against taste-graph and directory names.
  module Names
    DOMAIN_SUFFIX = /\.(?:com|co|io|app|net|org|fm|ai|tv)\z/i
    # Containment matches need this many characters, so "art" can't match "smart".
    MIN_CONTAINED = 4

    module_function

    # A comparison key: downcased, trailing punctuation and domain suffix removed, leading "the" dropped,
    # "&" read as "and", and everything but letters and digits removed ("The Founder's Ledger" => "foundersledger").
    def normalize(name)
      key = name.to_s.downcase.strip.sub(/[[:punct:][:space:]]+\z/, "")
      key = key.sub(DOMAIN_SUFFIX, "").sub(/\Athe\s+/, "").gsub("&", " and ")
      key.gsub(/[^[:alnum:]]+/, "")
    end

    def same?(a, b)
      key = normalize(a)
      key.present? && key == normalize(b)
    end

    # Equal, or one contains the other ("Tim Ferriss" ~ "The Tim Ferriss Show").
    def close?(a, b)
      short, long = [ normalize(a), normalize(b) ].sort_by(&:length)
      return false if short.empty?

      short == long || (short.length >= MIN_CONTAINED && long.include?(short))
    end
  end
end
