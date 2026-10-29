module Sponsors
  # The word lists sponsor detection checks against: config/sponsor_scan.yml (platform domains, words that never start
  # a brand name, words a show's name is made of that say nothing) plus config/proven_scan.yml's brand denylist and
  # webmail list (Research::ProvenSponsorScan, R32). Every list is compared normalized.
  module Rules
    module_function

    # A site a show links to that is never the sponsor of a read (YouTube, Patreon, a link shortener, Amazon).
    def platform_domain?(domain) = domain.present? && platform_domains.include?(domain)

    # A brand name that is a platform, self-promotion, a stray word ("Our", "Email") or too short to mean anything.
    def not_a_brand?(name)
      key = Research::ProvenSponsorScan.key_for(name)
      first = Research::Names.normalize(name.to_s.split(/\s+/).first)
      Research::ProvenSponsorScan.denylisted?(name) || not_brands.include?(key) || not_brands.include?(first)
    end

    def generic_word?(word) = generic_words.include?(word.to_s.downcase)

    def platform_domains
      @platform_domains ||= Array(config[:platform_domains]).filter_map { |d| Brand.normalize_domain(d) }.to_set
    end

    def not_brands = @not_brands ||= Array(config[:not_brands]).map { |w| Research::Names.normalize(w) }.to_set

    def generic_words = @generic_words ||= Array(config[:generic_words]).map { |w| w.to_s.downcase }.to_set

    def config = Rails.application.config_for(:sponsor_scan)
  end
end
