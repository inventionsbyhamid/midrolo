module Sponsors
  # Stage 1 of sponsor detection, for one episode's notes (plain text, line breaks kept): the sponsor reads the text
  # itself shows, without a model.
  #
  # Strong signals: a lead-in ("brought to you by", "thanks to our sponsors", "support for this episode comes from",
  # "Today's sponsor is", "Sponsors:"; Research::ProvenSponsorScan's first pattern, widened to lists and lowercase-led
  # names), a line in a "Sponsors" block, a promo code next to a brand's domain ("use code TIM at drinkag1.com"), and a
  # vanity path made for the show ("shopify.com/tim"). Weak ones (an offer next to a domain, "presented by", a lead-in
  # inside a thank-you to patrons) are only hints for the model (stage 2), which alone may confirm them.
  #
  # Each Candidate keeps the sentences it was read from, so its evidence is the show's own words. Platforms, the show's
  # own names and domains, ad choices and privacy notices never count.
  class Notes
    STRONG = %i[lead_in section code vanity].freeze
    EVIDENCE_LIMIT = SponsorMention::EVIDENCE_LIMIT
    OFFER_LIMIT = SponsorMention::OFFER_LIMIT
    NAME_LIMIT = 60
    # A read runs from its lead-in over at most this many following sentences ("Go to notion.com/lex. Use code LEX.").
    READ_SPAN = 2
    # A "Sponsors" block ends at the next heading or after this many lines.
    SECTION_LINES = 16
    # The most of one episode's notes the model reads (Sponsors::LlmCheck), in characters.
    MODEL_TEXT_LIMIT = 2000
    # A sentence too long for the room left is cut to fit when at least this much room is left.
    MODEL_PIECE_MIN = 200

    # A brand name as show notes write it: capitalised words ("Athletic Greens", "Hims & Hers"), a lowercase-led
    # capital ("iHeart", "eBay"), a digit-led one ("1Password", "23andMe").
    WORD = /(?:\p{Lu}|\d+\p{L}|\p{Ll}(?=\p{Lu}))[[:word:]'’.+!-]*/
    NAME = /#{WORD}(?:[ ](?:&[ ])?(?:\p{Lu}|\d)[[:word:]'’.+!-]*){0,3}/

    # Lead-ins, case-insensitive. Strong ones open sponsor reads; weak ones open other credits too.
    STRONG_LEADS = [
      /\bbrought to you by\b/i,
      /\bthanks to (?:our|today'?s|this (?:episode|week)'?s) sponsors?\b[,:]?/i,
      /\bsupport for (?:this|the|today'?s) (?:episode|show|podcast|program) (?:comes|is provided) (?:from|by)\b/i,
      /\b(?:today'?s|this (?:episode|week)'?s|our) sponsors? (?:today |this week )?(?:is|are|include|includes)\b:?/i,
      /(?:\A|[\s(\[*•·|])sponsors?:/i
    ].freeze
    SPONSORED_BY = /\bsponsored by\b/i
    # "sponsored by" opens a read when the show is the subject ("This episode is sponsored by") or it opens the
    # sentence; "a study sponsored by" doesn't.
    SPONSORED_SUBJECT = /(?:\A[\W\d]*|\b(?:episode|show|podcast|today|week|program|edition|segment|hour|series|this|it)\W+(?:is |was |are |has been |is being |'s )?)\z/i
    WEAK_LEADS = [ /\bpresented by\b/i, /\bsupported by\b/i, /\bmade possible by\b/i, /\bin partnership with\b/i,
                   /\bpartnered with\b/i ].freeze
    THANKS_FOR_SPONSORING = /\b(?i:thank(?:s| you) to )(#{NAME})(?i: for sponsoring)\b/
    FRIENDS_AT = /\A(?:our (?:good )?(?:friends|partners|pals|sponsors?) (?:at|over at|from)|the (?:good )?(?:folks|team|people) (?:at|over at|from))\s+/i
    NEGATED = /(?:\bnot|n't|\bnever|\bno)\s+(?:\w+\s+){0,2}\z/i
    # A lead-in in a thank-you to listeners or patrons is no sponsor read on its own.
    PATRONS = /\bpatreon\b|\bpatrons?\b|\bsupporters?\b|\blisteners like you\b|\bmembers\b|\bdonors?\b|\bbackers?\b/i
    LIST_SPLIT = /\s*(?:,|;|\band\b|\bplus\b|\bas well as\b)\s*/
    # A sentence that sends listeners somewhere ("Go to drinkag1.com/tim"): its link belongs to the read before it.
    CALL_TO_ACTION = /\A\W*(?:go|head|visit|check|sign up|try|get|use|start|text|download|learn|claim|order|shop|join|click|see|save|for)\b/i

    # A line that only heads a block of sponsors ("SPONSORS:", "Today's sponsors", "*Thanks to our sponsors*").
    SECTION_HEADER = /\A[\W_]*(?:(?:this (?:episode|show) is |today'?s |this (?:episode|week)'?s |our |episode |show )?(?:sponsors?|sponsored by|brought to you by|thanks to our sponsors?|support for this (?:episode|show) comes from))[\W_]*\z/i
    # A line that heads some other block: all capitals ("OUTLINE:", "EPISODE LINKS") or a usual heading word.
    CAPS_HEADER = /\A[\W_]*\p{Lu}[\p{Lu}\d '&]{2,40}[\W_]*\z/
    NAMED_HEADER = /\A[\W_]*(?:episode |show |podcast )?(?:links|timestamps|outline|chapters|resources|credits|follow(?: us)?|connect|contact|transcript|show notes|notes|guests?|about|music|references|mentioned|books|socials|subscribe|support(?: the show)?|find us|where to find us|more)[\W_]*\z/i
    # "Notion: the workspace", "Notion (notion.com/lex)", "Notion - notion.com/lex", "Notion https://notion.com/lex".
    SECTION_ENTRY = /\A[\W_]*(#{NAME})\s*(?::|\(|\s[-–—|]\s|\shttps?:|\s(?:www\.)?[a-z0-9-]+\.[a-z]{2,})/
    # A line that is only a name ("BetterHelp", "- HelloFresh").
    BARE_ENTRY = /\A[\W_]*(#{NAME})[\W_]*\z/

    TLDS = %w[com net org co io ai app fm tv me us uk ca au de fr nl se no dk fi es it ie nz in so sh gg ly to xyz club
              shop store health life fit coffee news blog link page site online tech dev studio media show live cash money
              finance bank insurance vip pro biz info energy care golf bio pet run games audio music art design agency team
              works tools world email ch at be eu jp kr br mx za sg hk tw cz pl pt gr].freeze
    DOMAIN = %r{(?<![@\w.-])(?:https?://)?(?:www\.)?((?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:#{TLDS.join('|')}))(?![\w-])(/[^\s<>"'“”‘’()\[\]{},]*)?}i
    DOMAIN_NAME = /\A[\w-]+\.(?:#{TLDS.join('|')})\z/i
    CODE = /\b(?:(?:use|enter|with|apply|promo|offer|discount|coupon)\s+(?:the\s+|my\s+|our\s+)?(?:promo\s+|offer\s+|discount\s+|coupon\s+)?code|code)\s*(?:is\s+)?:?\s*["“'‘]?(\p{Alnum}{2,20})(?!\p{Alnum})/i
    CODE_STOPWORDS = %w[at for to the and when below above link in on is it or here this that you your of].to_set.freeze
    OFFER = /(?:\b(?:get|save|enjoy|receive|claim|take)\s+)?(?:(?:up to\s+)?\d{1,3}\s?%\s?off|\$\d[\d,]*(?:\.\d\d)?\s+off|\d{1,3}\s?%\s+discount|free (?:trial|shipping|month|gift|year|bottle|sample|bag|box|week)s?|(?:a |your |one )?(?:first|1st) (?:month|order|box|year|bag)s? (?:free|for free|for \$\d+|half off)|\d+ (?:days|weeks|months) free|buy one,? get one)[^.!?\n,;]{0,60}/i
    # The host plugging their own thing ("our new course", "my book"): a code or vanity link next to it is no sponsor
    # read on its own.
    SELF_PLUG = /\b(?:our|my)\s+(?:\w+\s+){0,2}?(?:course|book|merch|store|shop|newsletter|community|membership|class|workshop|program|app|tour|live show|event|tickets?|swag|shirts?|hoodies?|mugs?|products?|company|startup|agency|coaching)\b/i
    AD_WORDS = /\bsponsor|\bpromo\b|\bdiscount|\bdeal\b|\boffer\b|\bcoupon|\bcode\b|\btrial\b|\bexclusive\b|% off/i
    # Dynamic ad insertion and privacy notices: a monetization hint, never a sponsor ("Learn more about your ad
    # choices. Visit megaphone.fm/adchoices", "Hosted on Acast. See acast.com/privacy").
    BOILERPLATE = %r{ad ?choices|privacy (?:information|policy|notice|& opt-out|and opt-out)|omnystudio\.com/listener|acast\.com/privacy|podcastchoices\.com|advertising inquiries|advertise (?:on|with) (?:this|our|the|us)|interested in (?:advertising|sponsoring)|become a sponsor|sponsor (?:this|the|our) (?:show|podcast)|hosted (?:on|by) (?:acast|simplecast|libsyn|anchor|buzzsprout|transistor|megaphone|art19|podbean|spreaker|captivate|redcircle|audioboom)}i
    SENTENCE_SPLIT = /(?<=[.!?])\s+(?=["“(\[]?[\p{Lu}\d])/
    # A word brands put before their name in a domain ("drinkag1.com", "getquip.com", "trybasis.com").
    DOMAIN_PREFIX = /\A(?:drink|get|try|join|go|use|shop|buy|with|hello|meet|the)(?=.{3})/
    # A sentence that may be part of a read, so it reaches the model first when the notes are long.
    READ_SIGNAL = Regexp.union(AD_WORDS, CODE, OFFER, SPONSORED_BY, *STRONG_LEADS, *WEAK_LEADS,
                               /\bbrought to you\b|\bour (?:friends|partners) at\b|\bpromo\b|\bsponsor/i)

    Unit = Data.define(:index, :text, :line)
    Link = Data.define(:domain, :url, :slug, :position)

    # One sponsor this episode's notes point at, before its brand is resolved.
    class Candidate
      attr_accessor :name, :domain, :url, :promo_code, :offer, :evidence
      attr_reader :signals, :units

      def initialize(name: nil, signals: [], units: [])
        @name = name
        @signals = Set.new(signals)
        @units = units.dup
      end

      def strong? = @signals.intersect?(STRONG)

      # Only a hint for the model.
      def weaken! = @signals.subtract(STRONG) << :hint

      def key = domain.presence || Research::ProvenSponsorScan.key_for(name)

      def domain_named? = name.present? && name == domain

      # Same brand: one domain, one name, or a name the other's domain is named after ("LMNT" and drinklmnt.com).
      def same_brand?(other)
        return domain == other.domain if domain && other.domain
        return true if Research::ProvenSponsorScan.key_for(name) == Research::ProvenSponsorScan.key_for(other.name)

        Notes.name_matches_domain?(name, other.domain) || Notes.name_matches_domain?(other.name, domain)
      end

      def absorb(other)
        @signals.merge(other.signals)
        @units |= other.units
        self.name = other.name if domain_named? && other.name.present? && !other.domain_named?
        self.domain ||= other.domain
        self.url ||= other.url
        self.promo_code ||= other.promo_code
        self.offer ||= other.offer
        self
      end
    end

    # The domain's label, with or without a "drink", "get" or "try" prefix, holds the name's key or is held by it
    # ("AG1" and drinkag1.com, "Athletic Greens" and athleticgreens.com).
    def self.name_matches_domain?(name, domain)
      return false if name.blank? || domain.blank?

      key = Research::ProvenSponsorScan.key_for(name)
      label = domain.split(".").first.to_s.delete("-")
      return false if key.length < 2 || label.length < 2

      bare = label.sub(DOMAIN_PREFIX, "")
      [ label, bare ].uniq.any? { |l| l == key || (key.length >= 3 && l.include?(key)) || (l.length >= 4 && key.include?(l)) }
    end

    # Text cut to the evidence limit at word boundaries, starting a little before the first of terms when it's far in,
    # without a list's leading bullet ("* This episode", "- Vanta").
    def self.snippet(text, terms)
      focus = terms.compact.filter_map { |term| text.downcase.index(term.downcase) }.min.to_i
      start = focus > EVIDENCE_LIMIT / 2 ? text.rindex(/\s/, focus - (EVIDENCE_LIMIT / 4)).to_i : 0
      text[start..].strip.sub(/\A[*•·#>+-]+\s*/, "").truncate(EVIDENCE_LIMIT, separator: " ")
    end

    def initialize(text, context)
      @context = context
      @units = split(text.to_s)
      @headers = Set.new
      @firm = Set.new
    end

    def candidates
      @candidates ||= merge(read_sections + read_lead_ins + read_links)
    end

    # The notes the model reads, one line each (blank lines and ad choices notices dropped): all of them when they fit
    # the limit. Longer notes keep the sentences most likely to hold a read first (the candidates', "Sponsors" headings,
    # ones with ad words, a code, an offer or a lead-in), then ones with a link, then the rest as room allows, in the
    # notes' order, with "..." where text was left out.
    def for_model(limit = MODEL_TEXT_LIMIT)
      return model_lines(@units.map(&:index)) if text.length <= limit

      chosen = {}
      room = limit
      model_priority.each do |i|
        piece = @units[i].text
        piece = piece.truncate(room - 1, separator: " ") if piece.length >= room && room > MODEL_PIECE_MIN
        next if piece.length >= room

        chosen[i] = piece
        room -= piece.length + 1
      end
      model_lines(chosen.keys.sort, chosen)
    end

    # The notes as scanned (ad choices and privacy notices dropped), one sentence a line. What the model quotes must
    # be in here.
    def text = @text ||= @units.map(&:text).join("\n")

    # Every external domain the notes link to, for recurrence across episodes.
    def domains = @units.flat_map { |unit| external_links(unit.text).map(&:domain) }.uniq

    # The show's own words around the first of terms (a brand's name or domain), cut to the evidence limit; nil when
    # no sentence holds one.
    def quote(terms)
      terms = terms.compact_blank.map(&:downcase)
      unit = @units.find { |u| terms.any? { |term| u.text.downcase.include?(term) } }
      self.class.snippet(unit.text, terms) if unit
    end

    # Whether two terms (a brand's name and a domain) are in one sentence, or at most span sentences apart.
    def near?(first, second, span: 0)
      at = ->(term) { @units.select { |u| u.text.downcase.include?(term.downcase) }.map(&:index) }
      at.call(first).product(at.call(second)).any? { |i, j| (i - j).abs <= span }
    end

    private

    # ---- what the model reads ----

    # Unit indexes, the likeliest to hold a sponsor read first.
    def model_priority
      reads = (candidates.flat_map(&:units) + @headers.to_a + @units.select { |u| u.text.match?(READ_SIGNAL) }.map(&:index)).uniq
      links = @units.select { |u| u.text.match?(DOMAIN) }.map(&:index) - reads
      reads.sort + links + (@units.map(&:index) - reads - links)
    end

    # The chosen units as lines (pieces: a unit's text cut to fit): units of one line of the notes stay on one line;
    # "..." marks text left out.
    def model_lines(indexes, pieces = {})
      lines = []
      previous = nil
      indexes.each do |i|
        piece = pieces[i] || @units[i].text
        if previous && i == previous + 1 && @units[previous].line == @units[i].line
          lines[-1] = "#{lines[-1]} #{piece}"
        else
          lines << "..." if (previous.nil? && i.positive?) || (previous && i != previous + 1)
          lines << piece
        end
        previous = i
      end
      lines << "..." if previous && previous < @units.size - 1
      lines
    end

    # ---- units: sentences, line by line ----

    def split(text)
      units = []
      text.split(/\n+/).each_with_index do |line, line_index|
        line = line.gsub(/[[:space:]]+/, " ").strip
        next if line.empty?

        line.split(SENTENCE_SPLIT).each do |sentence|
          units << Unit.new(index: units.size, text: sentence, line: line_index) unless sentence.match?(BOILERPLATE)
        end
      end
      units
    end

    # ---- "Sponsors" blocks: one brand per line, its link on that line or the next ----

    # Line by line under a "Sponsors" heading. An entry ("Notion: note-taking", "- Vanta: vanta.com/x") or a line that
    # is only a link ("https://shopify.com/lex", "Go to drinkag1.com/sam") counts; the link on the line after an entry
    # is that entry's. The block ends at the next heading, or at the first other line once it has had an entry.
    # An entry stays strong only with a link named like it, a link right under it, or a code; otherwise (a bare name, a
    # "Guest: Jane (janedoe.com)" line) it's a hint for the model.
    def read_sections
      found = []
      section = nil
      current = nil
      @units.chunk_while { |a, b| a.line == b.line }.each do |units|
        text = units.map(&:text).join(" ")
        if text.match?(SECTION_HEADER)
          section = { header: units.first.index, ends: units.first.line + SECTION_LINES, entries: 0, skipped: 0 }
          current = nil
        elsif section && units.first.line <= section[:ends] && header?(text)
          section = nil
        elsif section && units.first.line <= section[:ends]
          kind, current = section_line(text, units.map(&:index), current, found)
          if kind == :other
            section[:skipped] += 1
            section = nil if section[:entries].positive? || section[:skipped] > 2
          else
            section[:entries] += 1
            @headers << section[:header]
          end
        end
      end
      found.each { |c| c.weaken! unless c.domain_named? || c.promo_code || @firm.include?(c) }
    end

    def header?(text) = text.match?(CAPS_HEADER) || text.match?(NAMED_HEADER)

    # [kind, the entry now open]: kind is :entry, :link, :continuation or :other.
    def section_line(text, indexes, current, found)
      links = external_links(text)
      bare_link = links.any? && text.sub(DOMAIN, "").sub(CALL_TO_ACTION, "").gsub(/\b(?:to|at|out)\b/i, "").match?(/\A[\W_]*\z/)
      name = clean_name(text[SECTION_ENTRY, 1] || text[BARE_ENTRY, 1])
      if name && brand_name?(name) && !bare_link
        current = Candidate.new(name: name, signals: [ :section ], units: indexes)
        found << current
        link = links.find { |l| self.class.name_matches_domain?(name, l.domain) }
        @firm << current if link
        attach_link(current, link || links.first)
        attach_code_and_offer(current, text)
        [ :entry, current ]
      elsif bare_link && current && current.domain.nil?
        attach_link(current, links.first)
        attach_code_and_offer(current, text)
        current.units.concat(indexes)
        @firm << current
        [ :continuation, current ]
      elsif bare_link
        current = Candidate.new(name: links.first.domain, signals: [ :section ], units: indexes)
        attach_link(current, links.first)
        attach_code_and_offer(current, text)
        found << current
        [ :link, current ]
      else
        [ :other, current ]
      end
    end

    # ---- lead-ins: "This episode is brought to you by Notion, Shopify and AG1." ----

    def read_lead_ins
      found = []
      @units.each do |unit|
        group = names_in(unit.text).map { |name, strength| Candidate.new(name: name, signals: [ strength ], units: [ unit.index ]) }
        next if group.empty?

        read_units(unit).each_with_index { |u, i| attribute(group, u, lead: i.zero?) }
        found.concat(group)
      end
      found
    end

    # [[name, :lead_in or :weak_lead]] for the lead-ins in one sentence.
    def names_in(text)
      patron = text.match?(PATRONS)
      found = []
      STRONG_LEADS.each do |lead|
        text.scan(lead) { found.concat(list_after(text, $~).map { |n| [ n, patron ? :weak_lead : :lead_in ] }) }
      end
      text.scan(SPONSORED_BY) do
        match = $~
        strength = !patron && text[0...match.begin(0)].match?(SPONSORED_SUBJECT) ? :lead_in : :weak_lead
        found.concat(list_after(text, match).map { |n| [ n, strength ] })
      end
      WEAK_LEADS.each { |lead| text.scan(lead) { found.concat(list_after(text, $~).map { |n| [ n, :weak_lead ] }) } }
      text.scan(THANKS_FOR_SPONSORING) { |(name)| found << [ clean_name(name), patron ? :weak_lead : :lead_in ] }
      found.select { |name, _| name.present? && brand_name?(name) }.uniq { |name, _| Research::ProvenSponsorScan.key_for(name) }
    end

    # The names a lead-in (match) lists, in order, until an item doesn't start with one ("Squarespace, the website
    # builder"). None after a negation ("This episode is not sponsored by").
    def list_after(text, match)
      return [] if text[0...match.begin(0)].match?(NEGATED)

      tail = text[match.end(0)..].to_s.sub(/\A[\s:,*•·-]+/, "").sub(FRIENDS_AT, "")
      names = []
      tail.split(LIST_SPLIT).each do |item|
        match = item.strip.match(/\A#{NAME}/)
        break unless match

        names << clean_name(match[0])
        break if match[0].match?(/[.!?]\z/)
      end
      names.compact
    end

    # The lead-in's sentence and up to READ_SPAN after it, stopping at the next lead-in or heading.
    def read_units(unit)
      units = [ unit ]
      @units[unit.index + 1, READ_SPAN].to_a.each do |u|
        break if u.text.match?(SECTION_HEADER) || names_in(u.text).any?

        units << u
      end
      units
    end

    # A read's links, codes and offers go to its brands: a link to the brand it's named after, else to the read's only
    # brand when it's in the lead-in's sentence or a call to action after it; a code or offer to the brand whose link
    # comes just before it, else the read's only brand.
    def attribute(group, unit, lead:)
      links = external_links(unit.text)
      links.each do |link|
        owner = group.find { |c| self.class.name_matches_domain?(c.name, link.domain) }
        owner ||= group.first if group.size == 1 && group.first.domain.nil? && (lead || unit.text.match?(CALL_TO_ACTION)) &&
                                 name_for(link.domain, unit.text).nil?
        next unless owner

        attach_link(owner, link)
        owner.units << unit.index unless owner.units.include?(unit.index)
      end
      # A later sentence's code or offer for the show's own site or a plug of its own isn't the read's.
      return if !lead && ((links.empty? && unit.text.match?(DOMAIN)) || unit.text.match?(SELF_PLUG))

      code_at = unit.text =~ CODE
      offer_at = unit.text =~ OFFER
      [ code_at, offer_at ].compact.each do |position|
        before = links.select { |l| l.position < position }.max_by(&:position)
        owner = before ? group.find { |c| c.domain == before.domain } : (group.first if group.size == 1)
        next unless owner

        attach_code_and_offer(owner, unit.text)
        owner.units << unit.index unless owner.units.include?(unit.index)
      end
    end

    # ---- links outside a read: codes, vanity paths, offers ----

    def read_links
      found = []
      @units.each do |unit|
        external_links(unit.text).each do |link|
          candidate = Candidate.new(name: name_for(link.domain, unit.text) || link.domain, units: [ unit.index ])
          attach_link(candidate, link)
          attach_code_and_offer(candidate, unit.text)
          following = @units[unit.index + 1]
          if candidate.promo_code.nil? && following && following.line <= unit.line + 1 && !following.text.match?(DOMAIN) &&
             !following.text.match?(SELF_PLUG) && (code = code_in(following.text))
            candidate.promo_code = code
            candidate.units << following.index
          end
          candidate.signals << :code if candidate.promo_code
          candidate.signals << :vanity if link.slug && @context.vanity_slug?(link.slug)
          candidate.signals << :hint if candidate.offer || unit.text.match?(AD_WORDS)
          candidate.weaken! if candidate.strong? && unit.text.match?(SELF_PLUG)
          found << candidate if candidate.signals.any?
        end
      end
      found
    end

    # ---- shared pieces ----

    def attach_link(candidate, link)
      return unless candidate && link
      return if candidate.domain && candidate.domain != link.domain

      candidate.domain ||= link.domain
      candidate.url ||= link.url
    end

    def attach_code_and_offer(candidate, text)
      candidate.promo_code ||= code_in(text)
      candidate.offer ||= offer_in(text)
    end

    # "20% off all mattress orders", cut at the clause's end or a whole word, without a trailing "at manscaped".
    def offer_in(text)
      match = text.match(OFFER) or return nil
      offer = match[0]
      offer = offer.sub(/\s*\S*\z/, "") if text[match.end(0)]&.match?(/[[:word:]]/)
      offer = offer.sub(/\s+(?:at|on|from|with|using|by|and|to|go to|visit)(?:\s+\S+)?\z/i, "")
      offer.strip.sub(/[[:punct:][:space:]]+\z/, "").truncate(OFFER_LIMIT, separator: " ").presence
    end

    # A code as people type it: capitals or digits ("TIM", "LEX20", "Tim"), never a word like "below".
    def code_in(text)
      text.scan(CODE).flatten.find do |code|
        next false if CODE_STOPWORDS.include?(code.downcase)

        code.match?(/\A[\p{Lu}\d]+\z/) || (code.match?(/\d/) && code.match?(/\p{L}/)) || code.match?(/\A\p{Lu}\p{Ll}+\z/)
      end
    end

    # External links in a sentence: not the show's own, not a platform, not webmail.
    def external_links(text)
      text.to_enum(:scan, DOMAIN).filter_map do
        match = $~
        domain = Brand.normalize_domain(match[1])
        next if domain.nil? || Rules.platform_domain?(domain) || @context.own_domain?(domain) || Brand.webmail?(domain)

        path = match[2].to_s.sub(/[.!?,;:]+\z/, "")
        segments = path.split(%r{[/?#]}).compact_blank
        slug = segments.first if segments.size == 1 && !path.include?("?") && !segments.first.include?(".")
        Link.new(domain: domain, url: Show.http_url("https://#{match[1].downcase}#{path}"), slug: slug, position: match.begin(0))
      end.uniq(&:domain)
    end

    # The capitalised name in the sentence the domain is named after ("Athletic Greens" for athleticgreens.com).
    def name_for(domain, text)
      codes = text.scan(CODE).flatten
      text.scan(/(?<![\w.])#{NAME}/).filter_map { |n| clean_name(n) }
          .find { |n| !codes.include?(n) && !n.match?(DOMAIN_NAME) && self.class.name_matches_domain?(n, domain) && brand_name?(n) }
    end

    # "Notion." => "Notion", "Notion’s" => "Notion", "Notion.so" => "Notion".
    def clean_name(name)
      return nil if name.blank?

      name = Research::ProvenSponsorScan.clean(name).sub(/['’]s\z/, "").strip
      name = name.split(".").first.to_s if name.match?(DOMAIN_NAME)
      name.first(NAME_LIMIT).presence
    end

    def brand_name?(name) = !Rules.not_a_brand?(name) && !@context.own_name?(name)

    # Candidates of one brand become one, each with its evidence.
    def merge(found)
      merged = []
      found.each do |candidate|
        next unless candidate.domain_named? || brand_name?(candidate.name)

        same = merged.find { |m| m.same_brand?(candidate) }
        same ? same.absorb(candidate) : merged << candidate
      end
      merged.each { |c| c.evidence = evidence_for(c) }
    end

    # The read's first sentence, and the one holding its link or code when that's another, cut to fit around the name.
    def evidence_for(candidate)
      first, *rest = candidate.units.sort
      parts = [ @units[first].text ]
      label = candidate.domain&.split(".")&.first
      extra = rest.find do |i|
        text = @units[i].text
        (label && text.downcase.include?(label)) || (candidate.promo_code && text.include?(candidate.promo_code))
      end
      parts << @units[extra].text if extra
      self.class.snippet(parts.join(" "), [ candidate.name, candidate.domain ])
    end
  end
end
