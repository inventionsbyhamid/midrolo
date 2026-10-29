# A company that sponsors podcasts: found in feeds (SponsorMention), or signed up to search (BrandMember, FitSearch).
# Brand.resolve (sponsor detection), Brand.for_onboarding ("I'm a brand") and Brand.find_existing (lookups only) are the
# only ways code finds one by name or domain.
#
# A brand's domain is set when it is made, or by an admin, and never by anything a person or a feed types: a work email
# at the domain verifies a member, who then reads the brand's requests, saved shows and searches (review C1). So a
# known domain only ever matches the brand already at it, and a name only matches when no domain is known.
class Brand < ApplicationRecord
  include HasPublicId
  include FriendlySlug
  include Workspace

  NAME_LIMIT = 120
  # Hosts that give every customer a subdomain but aren't on the Public Suffix List yet, kept apart the same way.
  EXTRA_SUFFIXES = %w[onmicrosoft.com].freeze

  has_many :sponsor_mentions, dependent: :delete_all
  has_many :members, class_name: "BrandMember", dependent: :delete_all
  has_many :users, through: :members
  has_many :fit_searches, dependent: :nullify
  has_many :conversations, dependent: :destroy
  has_many :saved_podcasts, dependent: :delete_all
  has_many :blocks, dependent: :delete_all

  normalizes :name, with: ->(name) { name.squish.first(NAME_LIMIT).presence }
  normalizes :domain, with: ->(domain) { normalize_domain(domain) }
  # Set when the brand is made; assigning it later raises (an admin changes it with update_all, review C1).
  attr_readonly :domain

  before_validation :assign_name_key
  before_validation :assign_slug, on: :create

  validates :name, :name_key, :slug, presence: true
  validates :slug, uniqueness: true
  validates :domain, uniqueness: true, allow_nil: true
  validate :domain_is_not_webmail

  # A website or address as the brand's domain: lowercase host, no scheme, path, port or "www.", cut to the
  # registrable part on the Public Suffix List, its private part included ("https://shop.Notion.so/x" => "notion.so",
  # "a.alpha.com.pl" => "alpha.com.pl", "alpha.myshopify.com" stays), so two companies never share one (final review
  # N3). nil for anything that isn't a dotted host name, and for a bare public suffix ("com.pl", "myshopify.com").
  def self.normalize_domain(value)
    host = value.to_s.strip.downcase.sub(%r{\A[a-z][a-z0-9+.-]*://}, "").sub(/\A[^@\/]*@/, "")
    host = host.split(%r{[/?#:]}).first.to_s.delete_suffix(".").delete_prefix("www.")
    labels = host.split(".")
    return nil if labels.size < 2 || labels.any? { |label| !label.match?(/\A[a-z0-9-]+\z/) }

    extra = EXTRA_SUFFIXES.find { |suffix| host == suffix || host.end_with?(".#{suffix}") }
    return (host == extra ? nil : "#{host.delete_suffix(".#{extra}").split(".").last}.#{extra}") if extra

    PublicSuffix.domain(host, ignore_private: false)
  end

  # The comparison key for brand names ("The Notion Co." and "notion co" are one).
  def self.name_key_for(name) = Research::Names.normalize(name)

  # The existing brand at the domain, else one by name: any with that name when no domain is given, or one with no
  # domain yet when one is. nil when there is none. A read only: it never creates or changes a brand (L6 resolves
  # competitor names and the brand a fit search is about this way).
  def self.find_existing(name:, domain: nil)
    domain = normalize_domain(domain)
    domain = nil if domain && webmail?(domain)
    found = find_by(domain: domain) if domain
    return found if found

    key = name_key_for(name)
    return nil if key.blank?

    named = where(name_key: key).order(:id)
    domain ? named.find_by(domain: nil) : named.first
  end

  # Sponsor detection's brand: the brand at the domain when one is known (else a new brand at it, even when a brand of
  # that name has no domain), the brand by name when none is (else a new one, named after its domain when no name is
  # given). It never gives a brand a domain or another name; the one change it makes is to a brand still named after
  # its domain ("manscaped.com"), which takes the same name written properly ("Manscaped": equal name keys).
  # Raises ArgumentError without a name or a domain.
  def self.resolve(name:, domain: nil)
    domain = normalize_domain(domain)
    domain = nil if domain && webmail?(domain)
    name = name.to_s.squish
    raise ArgumentError, "a brand needs a name or a domain" if name.empty? && domain.nil?

    once_more_if_taken do
      brand = domain ? find_by(domain: domain) : find_existing(name: name)
      brand ? brand.adopt_name!(name) : transaction(requires_new: true) { create!(name: name.presence || domain, domain: domain) }
    end
  end

  # "I'm a brand" (onboarding): the brand already at the website's domain, exactly as it is (the typed name is ignored;
  # the member is unverified until a work email at the domain checks out), else a new brand with this name and domain,
  # even when brands of that name exist (FriendlySlug gives it its own slug; merging brands is an admin's job).
  # Raises ArgumentError for a website that isn't a domain, or is free mail.
  def self.for_onboarding(name:, website:)
    domain = normalize_domain(website)
    raise ArgumentError, "a brand needs its company's website" if domain.nil? || webmail?(domain)

    name = name.to_s.squish.first(NAME_LIMIT)
    once_more_if_taken do
      find_by(domain: domain) || transaction(requires_new: true) { create!(name: name.presence || domain, domain: domain) }
    end
  end

  # Runs the find-or-create block again once when a parallel one took the domain or slug first (the unique index, or
  # the uniqueness check), so the second look finds the winner. Safe inside a transaction.
  def self.once_more_if_taken
    attempts = 0
    begin
      yield
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      raise if e.is_a?(ActiveRecord::RecordInvalid) && %i[domain slug].none? { |field| e.record.errors.of_kind?(field, :taken) }

      attempts += 1
      retry if attempts < 2
      raise
    end
  end
  private_class_method :once_more_if_taken

  # A name like "shopify.com", which only a domain gave the brand.
  def self.domain_like?(name) = name.to_s.match?(/\A[\w-]+(?:\.[\w-]+)+\z/)

  # Free mail (the webmail list in config/proven_scan.yml) can't be a brand's domain.
  def self.webmail?(domain)
    label = domain.to_s.split(".").first.to_s
    Research::ProvenSponsorScan.webmail_domains.include?(label) || Research::ProvenSponsorScan.webmail_domains.include?(domain.to_s)
  end

  def verified? = verified_at.present?

  # Brand.resolve's one change to a brand it found: a brand still named after its domain ("manscaped.com") takes the
  # same name written properly ("Manscaped"). A name with another key ("Scam Shop") changes nothing, so a feed can
  # never rename a brand into another one.
  def adopt_name!(name)
    return self unless name.present? && self.name == domain && !self.class.domain_like?(name)
    return self unless self.class.name_key_for(name) == name_key

    self.class.transaction(requires_new: true) { update!(name: name) }
    self
  end

  private

  def assign_name_key
    self.name_key = self.class.name_key_for(name) if name.present?
  end

  def assign_slug
    self.slug ||= self.class.free_slug(name, fallback: "brand", qualifiers: [ domain ])
  end

  def domain_is_not_webmail
    errors.add(:domain, "can't be a free email provider") if domain.present? && self.class.webmail?(domain)
  end
end
