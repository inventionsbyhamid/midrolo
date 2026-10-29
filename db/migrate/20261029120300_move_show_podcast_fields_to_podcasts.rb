# Shows become a user's workspace for a podcast (spec sections 3 and 10), keeping the data: pure SQL, no app models,
# no TRUNCATE, so reports (sample reports included), matches, kits and spend entries all stay. Each group of shows that
# point at the same feed becomes one podcast holding the podcast-level columns; the shows point at it and lose them.
#
# - Shows group by feed URL, normalized as Podcast.normalize_feed_url does (lowercase scheme and host, no trailing
#   slash), or by directory id when a show has no feed URL. Such a podcast keeps "directory:<id>" as its feed URL (a
#   placeholder ingest can't fetch), as there is nothing else to put in the column.
# - A podcast takes its columns from the group's verified show (the earliest verified), else its latest updated one.
# - One verified show per podcast: any later verification of the same podcast is cleared.
# - Each verified show's old kit slug is kept: as the podcast's slug (the earliest verified) and as a podcast_redirects
#   row, so /k/:slug keeps working after a rename. A podcast with no verified slug gets its title, parameterized in
#   SQL, plus 6 characters of its public id (as Podcast does).
# - Owner emails are not copied: the column is encrypted now, and SQL can't encrypt. Ingest reads them from the feed
#   again (Catalog::IngestPodcastJob).
# - A user who had one podcast twice (two spellings of the feed URL) keeps one show (the verified, else the oldest); the
#   other's reports, matches, verifications and kit (when the kept show has none) move to it.
class MoveShowPodcastFieldsToPodcasts < ActiveRecord::Migration[8.1]
  MOVED = { directory_id: :string, itunes_id: :string, feed_url: :string, title: :string, author: :string,
            description: :text, artwork_url: :string, categories: :jsonb, episode_count: :integer, language: :string,
            cadence_days: :integer, owner_email: :string, slug: :string, qloo_entity_id: :string,
            website: :string }.freeze
  SAMPLES_EMAIL = "samples@midrolo.com".freeze
  ONE_VERIFIED = "index_shows_one_verified_per_podcast".freeze
  MERGED_REPORT = "Something went wrong while researching. Nothing was charged. Try again.".freeze

  # The SQL twin of Podcast.normalize_feed_url.
  SCHEME_AND_HOST = "^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*".freeze
  TRIMMED = "btrim(s.feed_url, E' \\t\\r\\n')".freeze
  NORMALIZED_FEED = <<~SQL.squish.freeze
    NULLIF(regexp_replace(
      CASE WHEN #{TRIMMED} ~ '#{SCHEME_AND_HOST}'
           THEN lower(substring(#{TRIMMED} from '#{SCHEME_AND_HOST}')) || substring(#{TRIMMED} from '#{SCHEME_AND_HOST}(.*)$')
           ELSE #{TRIMMED} END,
      '/+$', ''), '')
  SQL
  # Close to String#parameterize, capped at 60 characters as Podcast.slug_base does (no transliteration: an accented
  # letter splits the word).
  SLUG_BASE = <<~SQL.squish.freeze
    COALESCE(NULLIF(btrim(left(btrim(regexp_replace(lower(x.title), '[^a-z0-9]+', '-', 'g'), '-'), 60), '-'), ''), 'podcast')
  SQL
  # Research::Names.normalize, which Podcast.title_key_for uses: no trailing punctuation, domain suffix or leading
  # "the", "&" as "and", letters and digits only.
  TITLE_KEY = <<~SQL.squish.freeze
    regexp_replace(replace(regexp_replace(regexp_replace(regexp_replace(lower(btrim(x.title)),
      '[[:punct:][:space:]]+$', ''), '\\.(com|co|io|app|net|org|fm|ai|tv)$', ''), '^the\\s+', ''), '&', ' and '),
      '[^[:alnum:]]+', '', 'g')
  SQL

  def up
    add_reference :shows, :podcast, foreign_key: true, index: true
    group_shows
    insert_podcasts
    link_shows
    merge_duplicate_shows
    change_column_null :shows, :podcast_id, false

    remove_index :shows, :slug
    remove_index :shows, %i[user_id directory_id]
    remove_index :shows, %i[user_id feed_url]
    remove_columns :shows, *MOVED.keys
    add_index :shows, %i[user_id podcast_id], unique: true
    add_index :shows, :podcast_id, unique: true, where: "verified_at IS NOT NULL", name: ONE_VERIFIED
  end

  # Structure and the podcast-level values come back; owner emails (never copied) and the shows a merge folded
  # together don't.
  def down
    remove_index :shows, name: ONE_VERIFIED
    remove_index :shows, %i[user_id podcast_id]
    MOVED.each { |column, type| add_column :shows, column, type }
    change_column_default :shows, :categories, from: nil, to: []
    copy_back_to_shows
    change_column_null :shows, :categories, false
    change_column_null :shows, :title, false
    add_index :shows, :slug, unique: true
    add_index :shows, %i[user_id directory_id], unique: true, where: "directory_id IS NOT NULL"
    add_index :shows, %i[user_id feed_url], unique: true, where: "feed_url IS NOT NULL"
    remove_reference :shows, :podcast, foreign_key: true, index: true
    execute "DELETE FROM podcast_redirects"
    execute "DELETE FROM podcasts"
  end

  private

  # show_podcast_keys: each show's group. podcast_sources: the show each group's podcast takes its columns from.
  def group_shows
    execute <<~SQL
      CREATE TEMP TABLE show_podcast_keys AS
      SELECT s.id AS show_id,
             COALESCE(#{NORMALIZED_FEED}, 'directory:' || NULLIF(btrim(s.directory_id), ''), 'show:' || s.id) AS key
      FROM shows s
    SQL
    execute <<~SQL
      CREATE TEMP TABLE podcast_sources AS
      SELECT DISTINCT ON (k.key) k.key, s.id AS show_id
      FROM show_podcast_keys k JOIN shows s ON s.id = k.show_id
      ORDER BY k.key, (s.verified_at IS NULL), s.verified_at, s.updated_at DESC, s.id
    SQL
  end

  # One podcast per group, keyed by its feed URL. A directory, Apple or Qloo id two groups share goes to the first, so
  # the unique indexes hold.
  def insert_podcasts
    execute <<~SQL
      INSERT INTO podcasts (public_id, slug, title, title_key, author, description, language, categories, feed_url,
                            website, apple_id, podcast_index_id, qloo_entity_id, artwork_url, episode_count,
                            cadence_days, source, claimed_at, next_fetch_at, created_at, updated_at)
      SELECT x.public_id, COALESCE(x.verified_slug, #{SLUG_BASE} || '-' || left(x.public_id, 6)), x.title,
             #{TITLE_KEY}, x.author, x.description, x.language, x.categories, x.key, x.website,
             CASE WHEN row_number() OVER (PARTITION BY x.apple_id ORDER BY x.key) = 1 THEN x.apple_id END,
             CASE WHEN row_number() OVER (PARTITION BY x.podcast_index_id ORDER BY x.key) = 1 THEN x.podcast_index_id END,
             CASE WHEN row_number() OVER (PARTITION BY x.qloo_entity_id ORDER BY x.key) = 1 THEN x.qloo_entity_id END,
             x.artwork_url, x.episode_count, x.cadence_days, x.source, x.verified_at, now(), x.created_at, now()
      FROM (
        SELECT ps.key, substr(replace(gen_random_uuid()::text, '-', ''), 1, 16) AS public_id,
               CASE WHEN s.verified_at IS NOT NULL THEN NULLIF(btrim(s.slug), '') END AS verified_slug,
               s.title, s.author, left(s.description, 4000) AS description, s.language, s.categories, s.website,
               s.artwork_url, COALESCE(s.episode_count, 0) AS episode_count, s.cadence_days, s.verified_at, s.created_at,
               CASE WHEN btrim(s.itunes_id) ~ '^[0-9]{1,18}$' THEN btrim(s.itunes_id)::bigint END AS apple_id,
               CASE WHEN btrim(s.directory_id) ~ '^[0-9]{1,18}$' THEN btrim(s.directory_id)::bigint END AS podcast_index_id,
               NULLIF(btrim(s.qloo_entity_id), '') AS qloo_entity_id,
               CASE WHEN u.email = '#{SAMPLES_EMAIL}' AND u.provider IS NULL THEN 'sample' ELSE 'claim' END AS source
        FROM podcast_sources ps JOIN shows s ON s.id = ps.show_id JOIN users u ON u.id = s.user_id
      ) x
    SQL
  end

  # shows.podcast_id; every verified show's kit slug as a redirect; then one verified show per podcast.
  def link_shows
    execute <<~SQL
      UPDATE shows SET podcast_id = p.id
      FROM show_podcast_keys k JOIN podcasts p ON p.feed_url = k.key
      WHERE shows.id = k.show_id
    SQL
    execute <<~SQL
      INSERT INTO podcast_redirects (from_slug, podcast_id, created_at, updated_at)
      SELECT btrim(s.slug), s.podcast_id, now(), now()
      FROM shows s
      WHERE s.verified_at IS NOT NULL AND NULLIF(btrim(s.slug), '') IS NOT NULL
      ON CONFLICT (from_slug) DO NOTHING
    SQL
    execute <<~SQL
      UPDATE shows SET verified_at = NULL
      WHERE verified_at IS NOT NULL AND id NOT IN (SELECT show_id FROM podcast_sources)
    SQL
    execute "DROP TABLE podcast_sources"
    execute "DROP TABLE show_podcast_keys"
  end

  # A user's second show of one podcast folds into the first: active reports on it are failed (one may be active per
  # show), then its reports, matches, verifications and kit (when the kept show has none) move over.
  def merge_duplicate_shows
    execute <<~SQL
      CREATE TEMP TABLE show_merges AS
      SELECT id AS show_id, keep_id FROM (
        SELECT id, first_value(id) OVER (PARTITION BY user_id, podcast_id ORDER BY (verified_at IS NULL), created_at, id) AS keep_id
        FROM shows
      ) ranked
      WHERE id <> keep_id
    SQL
    execute <<~SQL
      UPDATE reports SET status = 'failed', finished_at = now(), error_message = #{quote(MERGED_REPORT)}
      WHERE show_id IN (SELECT show_id FROM show_merges) AND status IN ('queued', 'running')
    SQL
    %w[reports sponsor_matches show_verifications].each do |table|
      execute "UPDATE #{table} SET show_id = m.keep_id FROM show_merges m WHERE #{table}.show_id = m.show_id"
    end
    execute <<~SQL
      DELETE FROM media_kits k USING show_merges m
      WHERE k.show_id = m.show_id
        AND (EXISTS (SELECT 1 FROM media_kits own WHERE own.show_id = m.keep_id)
             OR EXISTS (SELECT 1 FROM show_merges m2 JOIN media_kits k2 ON k2.show_id = m2.show_id
                        WHERE m2.keep_id = m.keep_id AND m2.show_id < m.show_id))
    SQL
    execute "UPDATE media_kits SET show_id = m.keep_id FROM show_merges m WHERE media_kits.show_id = m.show_id"
    execute "DELETE FROM shows WHERE id IN (SELECT show_id FROM show_merges)"
    execute "DROP TABLE show_merges"
  end

  # The podcast's columns back on every show of it; the slug only on its verified show.
  def copy_back_to_shows
    execute <<~SQL
      UPDATE shows SET
        directory_id = COALESCE(p.podcast_index_id::text,
                                CASE WHEN p.feed_url LIKE 'fake://%' THEN substr(p.feed_url, 8)
                                     WHEN p.feed_url LIKE 'directory:%' THEN substr(p.feed_url, 11) END),
        itunes_id = p.apple_id::text,
        feed_url = CASE WHEN p.feed_url LIKE 'directory:%' OR p.feed_url LIKE 'show:%' THEN NULL ELSE p.feed_url END,
        title = p.title, author = p.author, description = p.description, artwork_url = p.artwork_url,
        categories = p.categories, episode_count = p.episode_count, language = p.language,
        cadence_days = p.cadence_days, qloo_entity_id = p.qloo_entity_id, website = p.website,
        slug = CASE WHEN shows.verified_at IS NOT NULL THEN p.slug END
      FROM podcasts p WHERE p.id = shows.podcast_id
    SQL
  end
end
