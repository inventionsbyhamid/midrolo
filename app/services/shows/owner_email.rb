module Shows
  # The show owner's address as the RSS feed states it. Verification codes go here, so the order matters:
  # itunes:owner/itunes:email first, then podcast:email, then managingEditor ("editor@x.com (Name)").
  module OwnerEmail
    PATHS = %w[//channel/owner/email //channel/email //channel/managingEditor].freeze
    EMAIL = /[^\s<>()@,;]+@[^\s<>()@,;]+\.[^\s<>()@,;]+/

    module_function

    # feed is the feed's XML, or a Nokogiri document whose namespaces were already removed.
    def for(feed)
      doc = feed.is_a?(Nokogiri::XML::Document) ? feed : Nokogiri::XML(feed.to_s).tap(&:remove_namespaces!)
      PATHS.filter_map { |path| doc.at_xpath(path)&.text.to_s[EMAIL] }.first
    end

    # "jane@example.com" => "j***@example.com": enough for the owner to recognise, not enough to harvest.
    def mask(email)
      local, domain = email.to_s.split("@", 2)
      return nil if local.blank? || domain.blank?

      "#{local[0]}***@#{domain}"
    end
  end
end
