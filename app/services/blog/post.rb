module Blog
  # A blog post (R148): a Markdown file in content/blog with YAML front matter. The blog is the SEO growth channel, so
  # a post is a file in the repo, reviewed and deployed like code, with no admin screen or table behind it. Its slug is
  # its file name (how-to-price-a-midroll.md is /blog/how-to-price-a-midroll).
  #
  # Front matter: title, description (the meta description, about 150 to 160 characters) and published_on are
  # required; updated_on, author (Midrolo by default), tags and draft are optional. A missing field, a key it doesn't
  # know or a value of the wrong kind raises Invalid naming the file, so a typo never ships a half-read post.
  #
  # Posts are read once per process and kept, except in development, where an edit shows on the next request. Drafts
  # and posts dated after today are shown only in development (preview?); everywhere else they are 404s and are left
  # out of the index, the feed, the sitemap and the nav. A post dated today or earlier needs no deploy to go live: the
  # date is checked on each call.
  class Post
    class Invalid < StandardError; end

    DEFAULT_DIRECTORY = Rails.root.join("content/blog")
    REQUIRED = %w[title description published_on].freeze
    OPTIONAL = %w[updated_on author tags draft].freeze
    SLUG = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
    FRONT_MATTER = /\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)/m
    WORDS_PER_MINUTE = 225
    RELATED_LIMIT = 3

    class << self
      # Where posts are read from: content/blog, or what specs set (spec/support/blog_posts.rb).
      def directory = @directory || DEFAULT_DIRECTORY

      def directory=(path)
        @directory = path && Pathname(path)
        @all = nil
      end

      # Drafts and future posts show in development, so a writer can read a post before it goes live.
      def preview? = Rails.env.development?

      # "November 2, 2026", as the post page, the index and the share image write a date.
      def long_date(date) = date.strftime("%B %-d, %Y")

      # Every post in the directory, drafts and future ones too, newest first.
      def all
        return read_all if Rails.env.development?

        @all ||= read_all
      end

      # The posts a visitor can read, newest first.
      def published = preview? ? all : all.select(&:live?)

      # The published post at slug; ActiveRecord::RecordNotFound (a 404) for anything else, as Samples.find! does.
      def find!(slug)
        slug = slug.to_s
        published.find { |post| post.slug == slug } || raise(ActiveRecord::RecordNotFound, "no blog post #{slug.inspect}")
      end

      # A post from its file's text. path names the file in errors.
      def parse(source, slug:, path: "#{slug}.md")
        match = FRONT_MATTER.match(source) or raise Invalid, "#{path}: no front matter (a --- block at the top)"
        raise Invalid, "#{path}: name the file in lowercase words joined by hyphens" unless slug.match?(SLUG)

        data = front_matter(match[1], path)
        new(slug: slug, body: match.post_match, version: Digest::SHA256.hexdigest(source).first(16),
            **attributes(data, path))
      end

      private

      def read_all
        directory.glob("*.md").map { |path| parse(path.read(encoding: "UTF-8"), slug: path.basename(".md").to_s, path: path) }
                 .sort_by { |post| [ -post.published_on.jd, post.slug ] }.freeze
      end

      def front_matter(yaml, path)
        data = YAML.safe_load(yaml, permitted_classes: [ Date ])
        raise Invalid, "#{path}: the front matter isn't a list of keys" unless data.is_a?(Hash)

        unknown = data.keys.map(&:to_s) - REQUIRED - OPTIONAL
        raise Invalid, "#{path}: unknown front matter #{unknown.join(", ")}" if unknown.any?

        missing = REQUIRED.reject { |key| data[key].present? }
        raise Invalid, "#{path}: missing #{missing.join(", ")}" if missing.any?

        data
      rescue Psych::Exception => e
        raise Invalid, "#{path}: unreadable front matter (#{e.message})"
      end

      def attributes(data, path)
        { title: text(data, "title", path), description: text(data, "description", path),
          published_on: date(data, "published_on", path), updated_on: (date(data, "updated_on", path) if data["updated_on"]),
          author: data.key?("author") ? text(data, "author", path) : APP_NAME, tags: tags(data, path),
          draft: flag(data, "draft", path) }
      end

      def text(data, key, path)
        value = data[key]
        raise Invalid, "#{path}: #{key} must be text" unless value.is_a?(String) && value.strip.present?

        value.squish
      end

      def date(data, key, path)
        value = data[key]
        return value if value.is_a?(Date)

        Date.iso8601(value.to_s)
      rescue Date::Error
        raise Invalid, "#{path}: #{key} must be a date like 2026-11-02"
      end

      def tags(data, path)
        value = data.fetch("tags", [])
        raise Invalid, "#{path}: tags must be a list" unless value.is_a?(Array) && value.all?(String)

        value.map(&:squish).compact_blank.uniq(&:downcase)
      end

      def flag(data, key, path)
        value = data.fetch(key, false)
        raise Invalid, "#{path}: #{key} must be true or false" unless [ true, false ].include?(value)

        value
      end
    end

    attr_reader :slug, :title, :description, :published_on, :updated_on, :author, :tags, :body, :version

    def initialize(slug:, title:, description:, published_on:, body:, version:, updated_on: nil, author: APP_NAME,
                   tags: [], draft: false)
      @slug = slug
      @title = title
      @description = description
      @published_on = published_on
      @updated_on = updated_on
      @author = author
      @tags = tags.freeze
      @body = body
      @version = version
      @draft = draft
    end

    def to_param = slug

    def draft? = @draft

    # Dated after today: it goes live on its date.
    def scheduled? = published_on > Date.current

    def live? = !draft? && !scheduled?

    # The date of the last real change: updated_on when given, else published_on.
    def modified_on = updated_on || published_on

    # As times (midnight in the app's zone), for the feed, the article tags and the JSON-LD.
    def published_at = published_on.in_time_zone
    def modified_at = modified_on.in_time_zone

    def html = rendered.html

    # For the feed: the same HTML without the headings' # links.
    def feed_html = rendered.feed_html

    # The h2s, as [id, text] pairs, when there are enough of them (3 or more) to be worth a table of contents.
    def contents
      h2s = rendered.headings.select { |heading| heading.level == 2 }
      h2s.size >= 3 ? h2s.map { |heading| [ heading.id, heading.text ] } : []
    end

    def word_count = rendered.words

    def reading_minutes = [ (word_count / WORDS_PER_MINUTE.to_f).ceil, 1 ].max

    # Other published posts: those sharing the most tags first, then the newest.
    def related(limit: RELATED_LIMIT)
      mine = tags.map(&:downcase)
      others = self.class.published.reject { |post| post.slug == slug }
      others.each_with_index.sort_by { |post, index| [ -(post.tags.map(&:downcase) & mine).size, index ] }
            .map(&:first).first(limit)
    end

    private

    # Rendered once per post; the post itself is kept for the process.
    def rendered = @rendered ||= Markdown.render(body)
  end
end
