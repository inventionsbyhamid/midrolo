module Blog
  # A post's Markdown as HTML (R148): CommonMark with GitHub's tables, strikethrough, autolinks, task lists and
  # footnotes, through commonmarker. Raw HTML is left out (commonmarker's default) and so are javascript: links, so a
  # post can't add a script or a style. Three of commonmarker's defaults are off: syntax highlighting (its inline styles
  # would need the CSP loosened), hard breaks (a post's source wraps at any width) and emoji shortcodes. Smart
  # punctuation stays off too: it turns -- into a dash, which the copy rules forbid.
  #
  # Then, with Nokogiri: an h1 becomes an h2 (the page's h1 is the post's title), every h2 and h3 gets an id and (on the
  # page, not in the feed) a # link to itself, images load lazily, a table scrolls in its own box on a phone, and
  # commonmarker's "raw HTML omitted" comments go.
  module Markdown
    OPTIONS = { parse: { smart: false },
                render: { unsafe: false, hardbreaks: false },
                extension: { table: true, strikethrough: true, autolink: true, tasklist: true, footnotes: true,
                             header_ids: nil, shortcodes: false } }.freeze
    PLUGINS = { syntax_highlighter: nil }.freeze

    Heading = Data.define(:level, :id, :text)
    # html is safe to render and feed_html is the same without the # links; headings are the h2s and h3s in order;
    # words counts the text a reader reads.
    Result = Data.define(:html, :feed_html, :headings, :words)

    module_function

    def render(markdown)
      fragment = Nokogiri::HTML5.fragment(Commonmarker.to_html(markdown.to_s, options: OPTIONS, plugins: PLUGINS))
      fragment.xpath(".//comment()").each(&:remove)
      words = fragment.text.split.size
      fragment.css("h1").each { |heading| heading.name = "h2" }
      named = name_headings(fragment)
      fragment.css("img").each { |image| image["loading"] = "lazy" }
      feed_html = fragment.to_html
      named.each { |node, heading| link_heading(node, heading.id) }
      fragment.css("table").each { |table| table.wrap(%(<div class="post-table" role="region" aria-label="Table" tabindex="0"></div>)) }

      Result.new(html: fragment.to_html.html_safe, feed_html: feed_html, headings: named.map(&:last), words: words)
    end

    # Each h2 and h3 gets an id from its text, unique in the post: [[node, Heading], ...].
    def name_headings(fragment)
      taken = Set.new
      fragment.css("h2, h3").map do |heading|
        text = heading.text.squish
        base = text.parameterize.presence || "section"
        id, count = base, 1
        id = "#{base}-#{count += 1}" while taken.include?(id)
        taken << id
        heading["id"] = id
        [ heading, Heading.new(level: heading.name[1].to_i, id: id, text: text) ]
      end
    end

    # A # link to the heading, after its text. It is for the pointer only (hidden from screen readers, out of the tab
    # order): the table of contents gives everyone the same links.
    def link_heading(heading, id)
      heading.add_child(%(<a class="heading-anchor" href="##{id}" aria-hidden="true" tabindex="-1">#</a>))
    end
  end
end
