module Pitches
  # The pitch pack in fake-LLM mode, written from the same Inputs as the live prompt. It names the brand and its
  # shared taste tags, keeps the body at 100–150 words, and cites only numbers on the allowlist (R49).
  class Template
    CONTACT_ROLES = {
      "easy_yes" => "Founder or Head of Marketing",
      "realistic" => "Partnerships or Influencer Marketing Manager",
      "long_shot" => "Head of Partnerships / Influencer Marketing, or their media agency"
    }.freeze
    DEFAULT_CONTACT_ROLE = "Head of Partnerships / Influencer Marketing".freeze

    def self.call(inputs) = new(inputs).call

    def initialize(inputs)
      @in = inputs
    end

    def call
      { "subject" => subject, "body" => body, "angles" => angles, "offer" => offer, "follow_up" => follow_up,
        "contact_role" => CONTACT_ROLES.fetch(@in.tier.to_s, DEFAULT_CONTACT_ROLE) }
    end

    private

    def subject
      [ "A mid-roll for #{brand} on #{title}", "A mid-roll for #{brand}" ].find { |text| text.length <= Writer::SUBJECT_LIMIT } ||
        "A mid-roll for #{brand}".truncate(Writer::SUBJECT_LIMIT, separator: " ")
    end

    def body
      [
        "Hi #{brand} team,",
        "I host #{title}, an independent podcast whose listeners already lean your way, and I'd love to talk about a sponsorship.",
        [ fit, proven_line || "That overlap is why a host-read spot would feel like a recommendation, not an interruption." ].join(" "),
        "I only take sponsors I'd happily recommend to a friend, and I read every spot myself.",
        offer_line,
        "Would you be open to a quick call, or shall I send over our media kit?",
        "Thanks,\n#{signer}"
      ].join("\n\n")
    end

    def fit
      tags = @in.shared_tags
      if tags.any?
        count = "#{tags.size} taste #{'signal'.pluralize(tags.size)}"
        affinity = ", with #{@in.affinity_percent}% affinity for your brand" if @in.affinity_percent
        "Qloo's taste data shows our audience shares #{count} with your fans, including #{tags.first(3).to_sentence}#{affinity}."
      else
        "Qloo's taste data shows a strong overlap between our listeners' tastes and #{[ @in.category, 'brands like yours' ].compact.join(' ')}."
      end
    end

    def proven_line
      show = @in.proven_show
      "You've also sponsored #{show}, a podcast much like ours, so you already know how listeners like ours respond." if show
    end

    def offer_line
      card = @in.rate_card
      reach = "With about #{@in.downloads.to_fs(:delimited)} downloads per episode, I" if @in.downloads
      "#{reach || 'I'}'d suggest a #{bundle} at #{@in.money(card.bundle4)}, #{@in.bundle_discount_percent}% off our " \
        "#{@in.money(card.midroll)} per-episode rate, read in my own words."
    end

    def angles
      tag = @in.shared_tags.first || @in.category
      [
        "Personal use: tell listeners how you'd actually use #{brand} yourself, in your own words, before any offer.",
        tag ? "Shared taste: tie #{brand} to #{tag}, something your listeners already love." :
              "Shared taste: tie #{brand} to the topics your listeners come to the show for.",
        if @in.proven_show
          "Familiar format: a conversational mid-roll like the ones #{brand} ran on #{@in.proven_show}, with a listener code."
        else
          "Low-key offer: a conversational mid-roll at the episode's natural break, with a listener code to track results."
        end
      ]
    end

    def offer
      card = @in.rate_card
      "#{bundle.capitalize}: #{@in.money(card.bundle4)} (#{@in.bundle_discount_percent}% off #{@in.money(card.midroll)} per episode). " \
        "Single spots: mid-roll #{@in.money(card.midroll)}, pre-roll #{@in.money(card.preroll)}, post-roll #{@in.money(card.postroll)}."
    end

    def follow_up
      tags = @in.shared_tags.first(2)
      overlap = tags.any? ? "share #{tags.to_sentence} with your fans" : "line up with brands like yours"
      "Hi #{brand} team,\n\nJust bringing my note about a mid-roll on #{title} back to the top of your inbox. " \
        "Our listeners #{overlap}, so I think a host-read spot would land well. Happy to send the media kit or hold " \
        "a slot for you, whichever is easier.\n\nThanks,\n#{signer}"
    end

    def bundle = "#{@in.bundle_episodes}-episode mid-roll bundle"

    def brand = @in.brand

    def title = @in.show_title

    def signer = @in.host || "The #{title} team"
  end
end
