# Readable slugs for public pages, as friendly_id makes them: "darknet-diaries", not "darknet-diaries-3f9a1c". A
# record takes the first free one of: its name parameterized; the name plus a qualifier ("the-daily-the-new-york-times");
# then the name numbered (-2, -3, ...). Words a route already uses never become a slug. The unique index on slug is the
# guarantee; this only picks well.
module FriendlySlug
  extend ActiveSupport::Concern

  LENGTH = 60
  RESERVED = %w[new edit search category categories page admin api feed].freeze

  class_methods do
    def friendly_slug_base(text, fallback)
      text.to_s.parameterize.first(LENGTH).delete_suffix("-").presence || fallback
    end

    # The first free slug for text among scope (all records, or a podcast's episodes). except is the record itself when
    # it renames, so its own slug doesn't count as taken. Slugs a model reserves (podcast redirects) count as taken.
    def free_slug(text, fallback:, qualifiers: [], scope: all, except: nil)
      base = friendly_slug_base(text, fallback)
      candidates = [ base, *qualifiers.filter_map { |q| qualified(base, q) } ].uniq
      taken = slugs_taken_like(base, scope, except)
      candidates.find { |slug| available?(slug, taken) } ||
        (2..).lazy.map { |n| "#{base}-#{n}" }.find { |slug| available?(slug, taken) }
    end

    private

    def qualified(base, qualifier)
      suffix = friendly_slug_base(qualifier, nil)
      "#{base}-#{suffix}".first(LENGTH).delete_suffix("-") if suffix && suffix != base
    end

    def available?(slug, taken) = !taken.include?(slug) && !RESERVED.include?(slug)

    def slugs_taken_like(base, scope, except)
      like = "#{sanitize_sql_like(base)}-%"
      relation = scope.where(slug: base).or(scope.where("#{table_name}.slug LIKE ?", like))
      relation = relation.where.not(id: except.id) if except&.persisted?
      relation.pluck(:slug).to_set.merge(reserved_slugs_like(base, like, except))
    end

    # Slugs that aren't columns of this table but still can't be given out (a podcast's old slugs, which redirect).
    def reserved_slugs_like(_base, _like, _except) = []
  end
end
