module Catalog
  # Feed text as plain text, the only form the catalog stores (build spec section 2): HTML becomes text, with <br> and
  # block elements as line breaks; scripts and styles go; every other run of whitespace is one space; control
  # characters (a NUL would break Postgres) are dropped; the result is capped. Never returns HTML for a page to render.
  module PlainText
    BLOCK_TAGS = Podcasts::FeedReader::BLOCK_TAGS
    # Text longer than this is cut before parsing, so one enormous description can't cost much.
    INPUT_LIMIT = 100_000
    CONTROL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/

    module_function

    # Multi-line plain text, at most limit characters, or nil when nothing is left.
    def call(html, limit:)
      return nil if html.nil?

      fragment = Nokogiri::HTML.fragment(html.to_s.scrub("").first(INPUT_LIMIT).gsub(CONTROL, ""))
      fragment.css("script, style").each(&:remove)
      fragment.css("br").each { |node| node.replace("\n") }
      fragment.css(BLOCK_TAGS).each do |node|
        node.before("\n")
        node.after("\n")
      end
      text = fragment.text.gsub(CONTROL, "").gsub(/[[:space:]&&[^\n]]+/, " ").gsub(/\s*\n\s*/, "\n").strip
      text.truncate(limit).presence
    end

    # One line (titles, names), at most limit characters, or nil.
    def line(html, limit:) = call(html, limit: limit * 2)&.squish&.truncate(limit)&.presence
  end
end
