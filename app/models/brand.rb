# A company that sponsors podcasts: found in feeds (SponsorMention), or signed up to search (BrandMember, FitSearch).
# Brand.resolve and Brand.find_existing are the only ways code finds one by name or domain.
class Brand < ApplicationRecord
  include HasPublicId
  include FriendlySlug
  include Workspace

  NAME_LIMIT = 120
  # Public suffixes of two labels, so "shop.example.co.uk" keeps "example.co.uk" (no public suffix list in the app).
  TWO_LABEL_SUFFIXES = %w[co.uk org.uk ac.uk gov.uk com.au net.au org.au co.nz co.jp co.in co.za com.br com.mx
                          com.sg com.hk com.cn co.kr com.tr com.ar co.il].to_set.freeze

  has_many :sponsor_mentions, dependent: :delete_all
  has_many :members, class_name: "BrandMember", dependent: :delete_all
  has_many :users, through: :members
  has_many :fit_searches, dependent: :nullify
  has_many :conversations, dependent: :destroy
  has_many :saved_podcasts, dependent: :delete_all
  has_many :blocks, dependent: :delete_all

  normalizes :name, with: ->(name) { name.squish.first(NAME_LIMIT).presence }
  normalizes :domain, with: ->(domain) { normalize_domain(domain) }

  before_validation :assign_name_key
  before_validation :assign_slug, on: :create

  validates :name, :name_key, :slug, presence: true
  validates :slug, uniqueness: true
  validates :domain, uniqueness: true, allow_nil: true
  validate :domain_is_not_webmail

  # A website or address as the brand's domain: lowercase host, no scheme, path, port or "www.", cut to the
  # registrable part ("https://shop.Notion.so/x" => "notion.so"). nil for anything that isn't a dotted host name.
  def self.normalize_domain(value)
    host = value.to_s.strip.downcase.sub(%r{\A[a-z][a-z0-9+.-]*://}, "").sub(/\A[^@\/]*@/, "")
    host = host.split(%r{[/?#:]}).first.to_s.delete_suffix(".").delete_prefix("www.")
    labels = host.split(".")
    return nil if labels.size < 2 || labels.any? { |label| !label.match?(/\A[a-z0-9-]+\z/) }

    keep = TWO_LABEL_SUFFIXES.include?(labels.last(2).join(".")) ? 3 : 2
    labels.last(keep).join(".")
  end

  # The comparison key for brand names ("The Notion Co." and "notion co" are one).
  def self.name_key_for(name) = Research::Names.normalize(name)

  # The existing brand at the domain, else one by name: any with that name when no domain is given, or one with no
  # domain yet when one is. nil when there is none; never creates one (L6 resolves competitor names this way).
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

  # find_existing, or a new brand (named after its domain when no name is given). A brand found by name gains the
  # domain it lacked, and one still named after its domain ("shopify.com") takes the first real name it's given.
  # Raises ArgumentError without a name or a domain. Safe inside a transaction, and against a parallel resolve: a
  # domain or slug taken meanwhile (the unique index, or the uniqueness check) means one more look before giving up.
  def self.resolve(name:, domain: nil)
    domain = normalize_domain(domain)
    domain = nil if domain && webmail?(domain)
    name = name.to_s.squish
    raise ArgumentError, "a brand needs a name or a domain" if name.empty? && domain.nil?

    attempts = 0
    begin
      brand = find_existing(name: name, domain: domain)
      brand ? brand.adopt!(name: name, domain: domain) : transaction(requires_new: true) { create!(name: name.presence || domain, domain: domain) }
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      raise if e.is_a?(ActiveRecord::RecordInvalid) && %i[domain slug].none? { |field| e.record.errors.of_kind?(field, :taken) }

      attempts += 1
      retry if attempts < 2
      raise
    end
  end

  # A name like "shopify.com", which only a domain gave the brand.
  def self.domain_like?(name) = name.to_s.match?(/\A[\w-]+(?:\.[\w-]+)+\z/)

  # Free mail (the webmail list in config/proven_scan.yml) can't be a brand's domain.
  def self.webmail?(domain)
    label = domain.to_s.split(".").first.to_s
    Research::ProvenSponsorScan.webmail_domains.include?(label) || Research::ProvenSponsorScan.webmail_domains.include?(domain.to_s)
  end

  def verified? = verified_at.present?

  # Brand.resolve's update of a brand it found: the domain it lacked, and a real name for one named after its domain.
  def adopt!(name:, domain:)
    changes = {}
    changes[:domain] = domain if domain && self.domain.nil?
    changes[:name] = name if name.present? && self.name == self.domain && !self.class.domain_like?(name)
    self.class.transaction(requires_new: true) { update!(changes) } if changes.any?
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
