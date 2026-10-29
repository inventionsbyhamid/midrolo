module ShareImages
  # A share image's SVG, 1200x630 on the paper colour: a label pill and the Midrolo logo along the top, the title (two
  # lines at most unless the card asks for more, as large as fits), a subline, one stat with an optional note, up to
  # three taste tags, and the show's waveform along the bottom with its mid-roll slot lit. With artwork, a right-hand
  # square either frames the picture (Renderer lays it on top) or, when it couldn't be fetched, holds the mark.
  #
  # Every string goes through Text: cleaned of what XML forbids, measured to wrap or shorten it with an ellipsis, then
  # XML-escaped, since show titles and authors come from RSS feeds. No string reaches an attribute.
  class Layout
    WIDTH = 1200
    HEIGHT = 630
    MARGIN = 72
    TEXT_WIDTH = WIDTH - MARGIN * 2
    ARTWORK = { x: 888, y: 160, size: 240 }.freeze
    ARTWORK_GAP = 48
    ARTWORK_RADIUS = 24

    COLORS = { ink: "#22132b", ink_soft: "#5a4a63", plum: "#4a2266", plum_soft: "#eee5f3", tally: "#f3a712",
               paper: "#f6f2f4", line: "#e3dae3", line_strong: "#8e7f95", white: "#ffffff" }.freeze
    # The families in vendor/fonts: ArchivoWide is Archivo at 125% width.
    TITLE_SIZES = [ 64, 56, 48 ].freeze
    CAP_HEIGHT = 0.686 # of the font size, in Archivo
    FONTS = { label: [ "Archivo", 600, 22 ], subline: [ "Archivo", 400, 26 ], stat: [ "ArchivoWide", 800, 40 ],
              stat_label: [ "Archivo", 400, 24 ], note: [ "Archivo", 400, 20 ], tag: [ "Archivo", 600, 22 ] }
              .transform_values { |(family, weight, size)| { family: family, weight: weight, size: size }.freeze }.freeze
    TAG_LIMIT = 3
    TAG_MAX_WIDTH = 360
    TAG_PADDING = 20
    # The top row's bottom edge, the lowest the text may reach, and the waveform's centre line below it.
    TOP_ROW_BOTTOM = MARGIN + 40
    DETAILS_BOTTOM = 500
    WAVE_Y = 566
    WAVE_BARS = 88
    WAVE_SLOT = 56 # the lit slot's place, near two thirds in, where a mid-roll sits

    # tags: the first TAG_LIMIT different ones are shown. artwork: nil (no artwork column), :image (a frame for the
    # picture) or :fallback (the mark). title_lines: how many lines the title may take (a blog post's takes three).
    def initialize(label:, title:, seed:, subline: nil, stat: nil, note: nil, tags: [], artwork: nil, title_lines: 2)
      @label = Text.clean(label)
      @title = Text.clean(title)
      @subline = Text.clean(subline)
      @stat = stat&.map { |part| Text.clean(part) }
      @note = Text.clean(note)
      @tags = Array(tags).map { |tag| Text.clean(tag) }.compact_blank.uniq(&:downcase).first(TAG_LIMIT)
      @seed = seed
      @artwork = artwork
      @max_title_lines = title_lines
    end

    def svg
      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="#{WIDTH}" height="#{HEIGHT}" viewBox="0 0 #{WIDTH} #{HEIGHT}">
        <rect width="#{WIDTH}" height="#{HEIGHT}" fill="#{COLORS[:paper]}"/>
        #{[ label_pill, logo, artwork_place, *body, waveform ].compact.join("\n")}
        </svg>
      SVG
    end

    private

    def column_width = @artwork ? ARTWORK[:x] - ARTWORK_GAP - MARGIN : TEXT_WIDTH

    def label_pill
      width = measure(@label, FONTS[:label]) + TAG_PADDING * 2
      %(<g data-role="label"><rect x="#{MARGIN}" y="#{MARGIN}" width="#{width}" height="40" rx="20" fill="#{COLORS[:plum_soft]}"/>) +
        text(@label, FONTS[:label], x: MARGIN + TAG_PADDING, y: MARGIN + 28, fill: :plum) + "</g>"
    end

    def logo
      height = 30
      width = (height * BrandMark::LOGO_RATIO).round(2)
      nested(:logo, x: WIDTH - MARGIN - width, y: MARGIN + 5, width: width, height: height)
    end

    def artwork_place
      x, y, size = ARTWORK.values_at(:x, :y, :size)
      case @artwork
      when :image
        %(<rect id="artwork-frame" x="#{x - 1}" y="#{y - 1}" width="#{size + 2}" height="#{size + 2}" rx="#{ARTWORK_RADIUS + 1}" fill="#{COLORS[:line]}"/>)
      when :fallback
        mark = size * 0.5
        %(<g id="artwork-fallback"><rect x="#{x}" y="#{y}" width="#{size}" height="#{size}" rx="#{ARTWORK_RADIUS}" fill="#{COLORS[:ink]}"/>) +
          nested(:mark_dark, x: x + (size - mark) / 2, y: y + (size - mark) / 2, width: mark, height: mark) + "</g>"
      end
    end

    # The title, subline and facts (stat, note, tags) flow as one block, so short content keeps together. With artwork
    # the block starts level with the artwork's top edge; without, it sits centred between the top row and the
    # waveform. Either way it ends above DETAILS_BOTTOM.
    def body
      size, lines = title_lines
      leading = (size * 1.08).round
      rows = [] # [kind, offset from the block's top], baselines except the tags' top edge
      y = (size * CAP_HEIGHT).round
      lines.each_index { |i| rows << [ :title, y + i * leading ] }
      y += [ lines.size - 1, 0 ].max * leading
      rows << [ :subline, y += 48 ] if @subline.present?
      rows << [ :stat, y += 64 ] if @stat
      rows << [ :note, y += 34 ] if @note.present?
      rows << [ :tags, y += (@stat || @note.present? ? 26 : 40) ] if @tags.any?
      height = @tags.any? ? y + 44 : y + 10
      top = @artwork ? ARTWORK[:y] : TOP_ROW_BOTTOM + (WAVE_Y - 24 - TOP_ROW_BOTTOM - height) / 2
      top = [ top, DETAILS_BOTTOM - height ].min
      draw_rows(rows, top, size, lines)
    end

    def draw_rows(rows, top, size, lines)
      font = { family: "ArchivoWide", weight: 800, size: size }
      title = rows.select { |kind, _| kind == :title }.zip(lines).map do |(_, offset), line|
        %(<tspan x="#{MARGIN}" y="#{top + offset}">#{Text.escape(line)}</tspan>)
      end
      [ %(<text data-role="title" #{font_attributes(font)} fill="#{COLORS[:ink]}">#{title.join}</text>) ] +
        rows.reject { |kind, _| kind == :title }.map { |kind, offset| row(kind, top + offset) }
    end

    def row(kind, y)
      case kind
      when :subline then text(shorten(@subline, FONTS[:subline], column_width), FONTS[:subline], x: MARGIN, y: y, fill: :ink_soft, role: "subline")
      when :stat then stat_row(y)
      when :note then text(shorten(@note, FONTS[:note], column_width), FONTS[:note], x: MARGIN, y: y, fill: :ink_soft, role: "note")
      when :tags then tag_row(y)
      end
    end

    # [font size, lines]: the largest size that shows the whole title in its lines, else the smallest, shortened.
    def title_lines
      TITLE_SIZES.each do |size|
        lines = Text.wrap(@title, { family: "ArchivoWide", weight: 800, size: size }, column_width, @max_title_lines)
        return [ size, lines ] if lines.join(" ") == @title || size == TITLE_SIZES.last
      end
    end

    def stat_row(baseline)
      value, label = @stat
      value_width = measure(value, FONTS[:stat])
      label_x = MARGIN + value_width + 14
      text(value, FONTS[:stat], x: MARGIN, y: baseline, fill: :ink, role: "stat") +
        text(shorten(label.to_s, FONTS[:stat_label], MARGIN + column_width - label_x), FONTS[:stat_label],
             x: label_x, y: baseline, fill: :ink_soft)
    end

    def tag_row(top)
      x = MARGIN
      chips = @tags.filter_map do |tag|
        label = shorten(tag, FONTS[:tag], TAG_MAX_WIDTH)
        width = measure(label, FONTS[:tag]) + TAG_PADDING * 2
        next if x + width > MARGIN + column_width

        chip = %(<g data-role="tag"><rect x="#{x}" y="#{top}" width="#{width}" height="44" rx="22" fill="#{COLORS[:white]}" ) +
               %(stroke="#{COLORS[:line]}" stroke-width="1.5"/>) +
               text(label, FONTS[:tag], x: x + TAG_PADDING, y: top + 29, fill: :ink) + "</g>"
        x += width + 10
        chip
      end
      chips.join
    end

    # The show's waveform, the same every time for a seed (as on its kit page), broken by the lit mid-roll slot: two
    # bars' room, a block like the mark's.
    def waveform
      random = Random.new(Zlib.crc32(@seed.to_s))
      step = TEXT_WIDTH / WAVE_BARS.to_f
      level = 0.5
      bars = Array.new(WAVE_BARS) do |i|
        level = (level * 0.55 + random.rand * 0.45).clamp(0.12, 1.0)
        next if (WAVE_SLOT..WAVE_SLOT + 1).cover?(i)

        height = (8 + level * 40).round
        %(<rect x="#{(MARGIN + i * step).round(1)}" y="#{WAVE_Y - height / 2.0}" width="6" height="#{height}" rx="3"/>)
      end
      slot_x = (MARGIN + WAVE_SLOT * step).round(1)
      %(<g data-role="waveform"><g fill="#{COLORS[:line_strong]}" opacity="0.45">#{bars.compact.join}</g>) +
        %(<rect x="#{slot_x}" y="#{WAVE_Y - 20}" width="#{(step + 6).round(1)}" height="40" rx="7" fill="#{COLORS[:tally]}"/></g>)
    end

    # A brand file (app/assets/images/brand) placed as a nested <svg>.
    def nested(name, x:, y:, width:, height:)
      svg = Nokogiri::XML(BRAND_FILES.fetch(name)).root
      svg.xpath("./comment()").each(&:remove)
      { x: x, y: y, width: width, height: height }.each { |key, value| svg[key.to_s] = value.round(2).to_s }
      svg.to_xml
    end

    def text(content, font, x:, y:, fill:, role: nil)
      role = %( data-role="#{role}") if role
      %(<text#{role} x="#{x.round(1)}" y="#{y.round(1)}" #{font_attributes(font)} fill="#{COLORS.fetch(fill)}">#{Text.escape(content)}</text>)
    end

    def font_attributes(font) = %(font-family="#{font[:family]}" font-weight="#{font[:weight]}" font-size="#{font[:size]}")

    def measure(content, font) = Renderer.text_width(content, **font)

    def shorten(content, font, width) = Text.shorten(content, font, width)

    BRAND_FILES = { logo: "logo.svg", mark_dark: "mark-dark.svg" }.transform_values do |file|
      Rails.root.join("app/assets/images/brand", file).read.freeze
    end.freeze
    private_constant :BRAND_FILES
  end
end
