# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_30_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "agent_steps", force: :cascade do |t|
    t.integer "position", default: 0, null: false
    t.string "tool"
    t.string "label", null: false
    t.string "status", default: "running", null: false
    t.text "input_summary"
    t.text "output_summary"
    t.integer "duration_ms"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "run_type", null: false
    t.bigint "run_id", null: false
    t.index ["run_type", "run_id", "position"], name: "index_agent_steps_on_run_type_and_run_id_and_position"
  end

  create_table "billing_events", force: :cascade do |t|
    t.string "provider", null: false
    t.string "event_id", null: false
    t.string "event_type"
    t.jsonb "payload", default: {}, null: false
    t.datetime "processed_at"
    t.string "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "event_id"], name: "index_billing_events_on_provider_and_event_id", unique: true
  end

  create_table "blocks", force: :cascade do |t|
    t.bigint "podcast_id", null: false
    t.bigint "brand_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["brand_id"], name: "index_blocks_on_brand_id"
    t.index ["podcast_id", "brand_id"], name: "index_blocks_on_podcast_id_and_brand_id", unique: true
  end

  create_table "brand_members", force: :cascade do |t|
    t.bigint "brand_id", null: false
    t.bigint "user_id", null: false
    t.string "role", default: "owner", null: false
    t.datetime "verified_at"
    t.string "code_digest"
    t.string "code_sent_to"
    t.datetime "code_expires_at"
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["brand_id", "user_id"], name: "index_brand_members_on_brand_id_and_user_id", unique: true
    t.index ["user_id"], name: "index_brand_members_on_user_id"
  end

  create_table "brands", force: :cascade do |t|
    t.string "public_id", null: false
    t.string "slug", null: false
    t.string "name", null: false
    t.string "name_key", null: false
    t.string "domain"
    t.string "qloo_entity_id"
    t.jsonb "categories", default: [], null: false
    t.jsonb "qloo_profile", default: {}, null: false
    t.integer "sponsor_mentions_count", default: 0, null: false
    t.datetime "verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["categories"], name: "index_brands_on_categories", using: :gin
    t.index ["domain"], name: "index_brands_on_domain", unique: true
    t.index ["name_key"], name: "index_brands_on_name_key"
    t.index ["public_id"], name: "index_brands_on_public_id", unique: true
    t.index ["qloo_entity_id"], name: "index_brands_on_qloo_entity_id", unique: true
    t.index ["slug"], name: "index_brands_on_slug", unique: true
  end

  create_table "conversations", force: :cascade do |t|
    t.string "public_id", null: false
    t.bigint "podcast_id", null: false
    t.bigint "brand_id", null: false
    t.bigint "started_by_id"
    t.string "status", null: false
    t.string "format"
    t.jsonb "months", default: [], null: false
    t.integer "budget_cents"
    t.datetime "last_message_at"
    t.datetime "first_reply_at"
    t.datetime "podcaster_read_at"
    t.datetime "brand_read_at"
    t.string "decline_reason"
    t.datetime "closed_at"
    t.datetime "reported_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["brand_id", "last_message_at"], name: "index_conversations_on_brand_id_and_last_message_at"
    t.index ["podcast_id", "brand_id"], name: "index_conversations_one_open_per_pair", unique: true, where: "((status)::text = ANY ((ARRAY['waiting_for_claim'::character varying, 'open'::character varying])::text[]))"
    t.index ["podcast_id"], name: "index_conversations_on_podcast_id"
    t.index ["public_id"], name: "index_conversations_on_public_id", unique: true
    t.index ["started_by_id", "created_at"], name: "index_conversations_on_started_by_id_and_created_at"
  end

  create_table "episodes", force: :cascade do |t|
    t.bigint "podcast_id", null: false
    t.string "guid", null: false
    t.string "slug", null: false
    t.string "title", null: false
    t.text "description"
    t.datetime "published_at"
    t.integer "duration_seconds"
    t.string "episode_type"
    t.integer "season"
    t.integer "number"
    t.string "enclosure_url"
    t.string "link"
    t.string "transcript_url"
    t.datetime "sponsor_scanned_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["podcast_id", "guid"], name: "index_episodes_on_podcast_id_and_guid", unique: true
    t.index ["podcast_id", "published_at"], name: "index_episodes_on_podcast_id_and_published_at", order: { published_at: :desc }
    t.index ["podcast_id", "slug"], name: "index_episodes_on_podcast_id_and_slug", unique: true
    t.index ["podcast_id"], name: "index_episodes_unscanned_on_podcast_id", where: "(sponsor_scanned_at IS NULL)"
  end

  create_table "fit_results", force: :cascade do |t|
    t.bigint "fit_search_id", null: false
    t.bigint "podcast_id", null: false
    t.integer "position"
    t.integer "score"
    t.float "taste_score"
    t.jsonb "reasons", default: [], null: false
    t.jsonb "proof", default: {}, null: false
    t.string "price_fit"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["fit_search_id", "podcast_id"], name: "index_fit_results_on_fit_search_id_and_podcast_id", unique: true
    t.index ["podcast_id"], name: "index_fit_results_on_podcast_id"
  end

  create_table "fit_searches", force: :cascade do |t|
    t.string "public_id", null: false
    t.bigint "user_id", null: false
    t.bigint "brand_id"
    t.string "query", null: false
    t.string "website"
    t.jsonb "categories", default: [], null: false
    t.integer "budget_cents"
    t.string "status", default: "queued", null: false
    t.string "qloo_brand_entity_id"
    t.text "summary"
    t.string "error_message"
    t.integer "taste_calls", default: 0, null: false
    t.decimal "cost_usd", precision: 10, scale: 5, default: "0.0", null: false
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["brand_id"], name: "index_fit_searches_on_brand_id"
    t.index ["public_id"], name: "index_fit_searches_on_public_id", unique: true
    t.index ["user_id", "created_at"], name: "index_fit_searches_on_user_id_and_created_at"
  end

  create_table "images", force: :cascade do |t|
    t.string "sha256", null: false
    t.string "source_url"
    t.integer "width"
    t.integer "height"
    t.string "content_type"
    t.datetime "suppressed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["sha256"], name: "index_images_on_sha256", unique: true
  end

  create_table "media_kits", force: :cascade do |t|
    t.bigint "show_id", null: false
    t.string "headline"
    t.text "about"
    t.jsonb "rate_card_overrides", default: {}, null: false
    t.jsonb "hidden_brand_ids", default: [], null: false
    t.datetime "published_at"
    t.integer "views_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "open_to_sponsors", default: false, null: false
    t.jsonb "open_months", default: [], null: false
    t.text "looking_for"
    t.jsonb "exclusions", default: [], null: false
    t.boolean "bands_only", default: false, null: false
    t.index ["show_id"], name: "index_media_kits_on_show_id", unique: true
  end

  create_table "messages", force: :cascade do |t|
    t.bigint "conversation_id", null: false
    t.bigint "user_id"
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "created_at"], name: "index_messages_on_conversation_id_and_created_at"
    t.index ["user_id"], name: "index_messages_on_user_id"
  end

  create_table "pitches", force: :cascade do |t|
    t.bigint "sponsor_match_id", null: false
    t.string "status", default: "queued", null: false
    t.string "subject"
    t.text "body"
    t.jsonb "angles", default: [], null: false
    t.text "offer"
    t.text "follow_up"
    t.string "contact_role"
    t.string "model"
    t.decimal "cost_usd", precision: 10, scale: 5, default: "0.0", null: false
    t.string "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "started_at"
    t.string "public_id", null: false
    t.index ["public_id"], name: "index_pitches_on_public_id", unique: true
    t.index ["sponsor_match_id"], name: "index_pitches_on_sponsor_match_id"
    t.index ["sponsor_match_id"], name: "index_pitches_one_queued_per_match", unique: true, where: "((status)::text = 'queued'::text)"
  end

  create_table "podcast_people", force: :cascade do |t|
    t.bigint "podcast_id", null: false
    t.string "name", null: false
    t.string "name_key", null: false
    t.string "role", default: "host", null: false
    t.string "href"
    t.string "img_url"
    t.bigint "image_id"
    t.integer "episodes_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["image_id"], name: "index_podcast_people_on_image_id"
    t.index ["podcast_id", "name_key", "role"], name: "index_podcast_people_on_podcast_id_and_name_key_and_role", unique: true
  end

  create_table "podcast_redirects", force: :cascade do |t|
    t.string "from_slug", null: false
    t.bigint "podcast_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["from_slug"], name: "index_podcast_redirects_on_from_slug", unique: true
    t.index ["podcast_id"], name: "index_podcast_redirects_on_podcast_id"
  end

  create_table "podcasts", force: :cascade do |t|
    t.string "public_id", null: false
    t.string "slug", null: false
    t.string "title", null: false
    t.string "title_key"
    t.string "author"
    t.text "description"
    t.string "language"
    t.boolean "explicit", default: false, null: false
    t.string "itunes_type"
    t.jsonb "categories", default: [], null: false
    t.string "feed_url", null: false
    t.string "website"
    t.bigint "apple_id"
    t.bigint "podcast_index_id"
    t.string "podcast_guid"
    t.string "qloo_entity_id"
    t.float "qloo_popularity"
    t.string "owner_email"
    t.string "artwork_url"
    t.bigint "artwork_image_id"
    t.string "hosting_provider"
    t.jsonb "measurement", default: [], null: false
    t.string "op3_show_uuid"
    t.integer "episode_count", default: 0, null: false
    t.datetime "first_published_at"
    t.datetime "last_published_at"
    t.integer "cadence_days"
    t.string "status", default: "pending", null: false
    t.boolean "indexable", default: false, null: false
    t.string "source", null: false
    t.boolean "open_to_sponsors", default: false, null: false
    t.datetime "claimed_at"
    t.integer "min_price_cents"
    t.integer "downloads_per_episode"
    t.string "downloads_trust"
    t.string "feed_etag"
    t.string "feed_last_modified"
    t.string "feed_sha256"
    t.datetime "feed_checked_at"
    t.datetime "next_fetch_at"
    t.datetime "leased_until"
    t.integer "fetch_failures", default: 0, null: false
    t.string "last_error"
    t.virtual "searchable", type: :tsvector, as: "((setweight(to_tsvector('simple'::regconfig, (COALESCE(title, ''::character varying))::text), 'A'::\"char\") || setweight(to_tsvector('simple'::regconfig, (COALESCE(author, ''::character varying))::text), 'B'::\"char\")) || setweight(to_tsvector('english'::regconfig, COALESCE(description, ''::text)), 'C'::\"char\"))", stored: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["apple_id"], name: "index_podcasts_on_apple_id", unique: true
    t.index ["artwork_image_id"], name: "index_podcasts_on_artwork_image_id"
    t.index ["categories"], name: "index_podcasts_on_categories", using: :gin
    t.index ["claimed_at"], name: "index_podcasts_on_claimed_at"
    t.index ["downloads_per_episode"], name: "index_podcasts_on_downloads_per_episode"
    t.index ["downloads_trust"], name: "index_podcasts_on_downloads_trust"
    t.index ["feed_url"], name: "index_podcasts_on_feed_url", unique: true
    t.index ["indexable"], name: "index_podcasts_on_indexable"
    t.index ["language"], name: "index_podcasts_on_language"
    t.index ["last_published_at"], name: "index_podcasts_on_last_published_at"
    t.index ["leased_until"], name: "index_podcasts_on_leased_until"
    t.index ["min_price_cents"], name: "index_podcasts_on_min_price_cents"
    t.index ["next_fetch_at"], name: "index_podcasts_on_next_fetch_at"
    t.index ["open_to_sponsors"], name: "index_podcasts_on_open_to_sponsors"
    t.index ["podcast_guid"], name: "index_podcasts_on_podcast_guid", unique: true
    t.index ["podcast_index_id"], name: "index_podcasts_on_podcast_index_id", unique: true
    t.index ["public_id"], name: "index_podcasts_on_public_id", unique: true
    t.index ["qloo_entity_id"], name: "index_podcasts_on_qloo_entity_id", unique: true
    t.index ["searchable"], name: "index_podcasts_on_searchable", using: :gin
    t.index ["slug"], name: "index_podcasts_on_slug", unique: true
    t.index ["status"], name: "index_podcasts_on_status"
    t.index ["title"], name: "index_podcasts_on_title_trigram", opclass: :gin_trgm_ops, using: :gin
    t.index ["title_key"], name: "index_podcasts_on_title_key"
  end

  create_table "removal_requests", force: :cascade do |t|
    t.bigint "podcast_id", null: false
    t.string "email"
    t.text "reason"
    t.string "status", default: "pending", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["podcast_id"], name: "index_removal_requests_on_podcast_id"
    t.index ["status"], name: "index_removal_requests_on_status"
  end

  create_table "reports", force: :cascade do |t|
    t.bigint "show_id", null: false
    t.string "kind", null: false
    t.string "status", default: "queued", null: false
    t.string "profile_kind"
    t.jsonb "seeds"
    t.jsonb "audience"
    t.jsonb "demographics"
    t.jsonb "heatmap"
    t.text "summary"
    t.string "error_message"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.decimal "cost_usd", precision: 10, scale: 5, default: "0.0", null: false
    t.integer "taste_calls", default: 0, null: false
    t.string "spend_bucket"
    t.string "sample_slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "viewed_at"
    t.datetime "ready_mailed_at"
    t.datetime "needs_input_mailed_at"
    t.string "public_id", null: false
    t.jsonb "similar_podcasts", default: [], null: false
    t.index ["public_id"], name: "index_reports_on_public_id", unique: true
    t.index ["sample_slug"], name: "index_reports_on_sample_slug", unique: true, where: "(sample_slug IS NOT NULL)"
    t.index ["show_id"], name: "index_reports_on_show_id"
    t.index ["show_id"], name: "index_reports_one_active_per_show", unique: true, where: "((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('running'::character varying)::text]))"
  end

  create_table "saved_podcasts", force: :cascade do |t|
    t.bigint "brand_id", null: false
    t.bigint "podcast_id", null: false
    t.bigint "user_id"
    t.string "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["brand_id", "podcast_id"], name: "index_saved_podcasts_on_brand_id_and_podcast_id", unique: true
    t.index ["podcast_id"], name: "index_saved_podcasts_on_podcast_id"
    t.index ["user_id"], name: "index_saved_podcasts_on_user_id"
  end

  create_table "service_sessions", force: :cascade do |t|
    t.string "platform", null: false
    t.text "credentials"
    t.string "status", default: "ok", null: false
    t.datetime "last_ok_at"
    t.string "last_error"
    t.datetime "expires_hint"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["platform"], name: "index_service_sessions_on_platform", unique: true
  end

  create_table "settings", force: :cascade do |t|
    t.string "key", null: false
    t.jsonb "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_settings_on_key", unique: true
  end

  create_table "show_verifications", force: :cascade do |t|
    t.bigint "show_id", null: false
    t.string "kind", null: false
    t.string "code_digest"
    t.string "token"
    t.string "sent_to"
    t.integer "attempts", default: 0, null: false
    t.datetime "expires_at", null: false
    t.datetime "verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["sent_to", "created_at"], name: "index_show_verifications_on_sent_to_and_created_at"
    t.index ["show_id", "created_at"], name: "index_show_verifications_on_show_id_and_created_at"
  end

  create_table "shows", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.integer "downloads_per_episode"
    t.string "country", default: "US", null: false
    t.string "contact_email"
    t.jsonb "hints", default: {"topics" => [], "comparable_shows" => []}, null: false
    t.datetime "verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "public_id", null: false
    t.bigint "podcast_id", null: false
    t.index ["podcast_id"], name: "index_shows_on_podcast_id"
    t.index ["podcast_id"], name: "index_shows_one_verified_per_podcast", unique: true, where: "(verified_at IS NOT NULL)"
    t.index ["public_id"], name: "index_shows_on_public_id", unique: true
    t.index ["user_id", "podcast_id"], name: "index_shows_on_user_id_and_podcast_id", unique: true
    t.index ["user_id"], name: "index_shows_on_user_id"
  end

  create_table "spend_entries", force: :cascade do |t|
    t.bigint "user_id"
    t.bigint "report_id"
    t.bigint "pitch_id"
    t.string "kind", default: "llm", null: false
    t.string "bucket", null: false
    t.string "model"
    t.integer "input_tokens", default: 0, null: false
    t.integer "output_tokens", default: 0, null: false
    t.integer "cache_read_tokens", default: 0, null: false
    t.integer "cache_write_tokens", default: 0, null: false
    t.decimal "cost_usd", precision: 10, scale: 5, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.bigint "fit_search_id"
    t.index ["bucket", "created_at"], name: "index_spend_entries_on_bucket_and_created_at"
    t.index ["fit_search_id"], name: "index_spend_entries_on_fit_search_id"
    t.index ["pitch_id"], name: "index_spend_entries_on_pitch_id"
    t.index ["report_id"], name: "index_spend_entries_on_report_id"
    t.index ["user_id"], name: "index_spend_entries_on_user_id"
  end

  create_table "sponsor_matches", force: :cascade do |t|
    t.bigint "report_id", null: false
    t.bigint "show_id", null: false
    t.string "brand_entity_id", null: false
    t.string "name"
    t.string "image_url"
    t.string "website"
    t.string "category"
    t.string "reason"
    t.float "affinity"
    t.float "popularity"
    t.integer "fit_score"
    t.string "tier"
    t.jsonb "evidence", default: {}, null: false
    t.string "status", default: "suggested", null: false
    t.text "notes"
    t.date "follow_up_on"
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "brand_description"
    t.string "public_id", null: false
    t.index ["public_id"], name: "index_sponsor_matches_on_public_id", unique: true
    t.index ["report_id", "brand_entity_id"], name: "index_sponsor_matches_on_report_id_and_brand_entity_id", unique: true
    t.index ["report_id"], name: "index_sponsor_matches_on_report_id"
    t.index ["show_id"], name: "index_sponsor_matches_on_show_id"
  end

  create_table "sponsor_mentions", force: :cascade do |t|
    t.bigint "podcast_id", null: false
    t.bigint "episode_id", null: false
    t.bigint "brand_id", null: false
    t.datetime "published_at"
    t.string "promo_code"
    t.string "offer"
    t.string "url"
    t.string "evidence"
    t.string "detected_by", null: false
    t.float "confidence"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["brand_id", "podcast_id"], name: "index_sponsor_mentions_on_brand_id_and_podcast_id"
    t.index ["episode_id", "brand_id"], name: "index_sponsor_mentions_on_episode_id_and_brand_id", unique: true
    t.index ["podcast_id", "published_at"], name: "index_sponsor_mentions_on_podcast_id_and_published_at"
  end

  create_table "stat_connections", force: :cascade do |t|
    t.bigint "podcast_id", null: false
    t.bigint "show_id"
    t.bigint "user_id"
    t.string "provider", null: false
    t.string "external_id"
    t.text "credentials"
    t.string "status", default: "pending_invite", null: false
    t.datetime "last_checked_at"
    t.datetime "activated_at"
    t.datetime "last_synced_at"
    t.string "last_error"
    t.datetime "file_checked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "approved_at"
    t.index ["podcast_id", "provider"], name: "index_stat_connections_on_podcast_id_and_provider", unique: true
    t.index ["show_id"], name: "index_stat_connections_on_show_id"
    t.index ["status"], name: "index_stat_connections_on_status"
    t.index ["user_id"], name: "index_stat_connections_on_user_id"
    t.index ["provider", "external_id"], name: "index_stat_connections_one_per_platform_show", unique: true, where: "((status)::text <> 'disconnected'::text)"
  end

  create_table "stat_readings", force: :cascade do |t|
    t.bigint "podcast_id", null: false
    t.string "metric", null: false
    t.bigint "value", null: false
    t.string "source", null: false
    t.string "trust", null: false
    t.integer "period_days"
    t.datetime "captured_at", null: false
    t.datetime "expires_at"
    t.jsonb "evidence", default: {}, null: false
    t.jsonb "breakdown", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_stat_readings_on_expires_at"
    t.index ["podcast_id", "metric", "source"], name: "index_stat_readings_on_podcast_id_and_metric_and_source", unique: true
  end

  create_table "subscriptions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "provider", null: false
    t.string "provider_customer_id"
    t.string "provider_subscription_id"
    t.string "price_key"
    t.string "plan", null: false
    t.string "status", null: false
    t.datetime "current_period_start"
    t.datetime "current_period_end"
    t.boolean "cancel_at_period_end", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "last_event_at"
    t.string "payment_ids", default: [], null: false, array: true
    t.index ["provider", "provider_subscription_id"], name: "index_subscriptions_on_provider_and_provider_subscription_id", unique: true, where: "(provider_subscription_id IS NOT NULL)"
    t.index ["user_id"], name: "index_subscriptions_on_user_id"
  end

  create_table "suppressions", force: :cascade do |t|
    t.string "kind", null: false
    t.string "value", null: false
    t.string "reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["kind", "value"], name: "index_suppressions_on_kind_and_value", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "email"
    t.string "name"
    t.string "avatar_url"
    t.string "provider"
    t.string "uid"
    t.boolean "admin", default: false, null: false
    t.boolean "judge", default: false, null: false
    t.datetime "deleted_at"
    t.datetime "remember_created_at"
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "current_sign_in_at"
    t.datetime "last_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "last_sign_in_ip"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "last_role"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true
    t.check_constraint "(provider IS NULL) = (uid IS NULL)", name: "users_provider_and_uid_together"
  end

  create_table "waitlist_entries", force: :cascade do |t|
    t.string "email", null: false
    t.string "price_key", null: false
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "notified_at"
    t.index "lower((email)::text), price_key", name: "index_waitlist_entries_on_lower_email_and_price_key", unique: true
    t.index ["user_id"], name: "index_waitlist_entries_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "blocks", "brands", on_delete: :cascade
  add_foreign_key "blocks", "podcasts", on_delete: :cascade
  add_foreign_key "brand_members", "brands", on_delete: :cascade
  add_foreign_key "brand_members", "users", on_delete: :cascade
  add_foreign_key "conversations", "brands"
  add_foreign_key "conversations", "podcasts"
  add_foreign_key "conversations", "users", column: "started_by_id", on_delete: :nullify
  add_foreign_key "episodes", "podcasts"
  add_foreign_key "fit_results", "fit_searches", on_delete: :cascade
  add_foreign_key "fit_results", "podcasts"
  add_foreign_key "fit_searches", "brands"
  add_foreign_key "fit_searches", "users", on_delete: :cascade
  add_foreign_key "media_kits", "shows"
  add_foreign_key "messages", "conversations", on_delete: :cascade
  add_foreign_key "messages", "users", on_delete: :nullify
  add_foreign_key "pitches", "sponsor_matches", on_delete: :cascade
  add_foreign_key "podcast_people", "images", on_delete: :nullify
  add_foreign_key "podcast_people", "podcasts"
  add_foreign_key "podcast_redirects", "podcasts", on_delete: :cascade
  add_foreign_key "podcasts", "images", column: "artwork_image_id", on_delete: :nullify
  add_foreign_key "removal_requests", "podcasts"
  add_foreign_key "reports", "shows"
  add_foreign_key "saved_podcasts", "brands", on_delete: :cascade
  add_foreign_key "saved_podcasts", "podcasts"
  add_foreign_key "saved_podcasts", "users", on_delete: :nullify
  add_foreign_key "show_verifications", "shows"
  add_foreign_key "shows", "podcasts"
  add_foreign_key "shows", "users"
  add_foreign_key "spend_entries", "fit_searches", on_delete: :nullify
  add_foreign_key "spend_entries", "reports", on_delete: :nullify
  add_foreign_key "spend_entries", "users", on_delete: :nullify
  add_foreign_key "sponsor_matches", "reports"
  add_foreign_key "sponsor_matches", "shows"
  add_foreign_key "sponsor_mentions", "brands"
  add_foreign_key "sponsor_mentions", "episodes"
  add_foreign_key "sponsor_mentions", "podcasts"
  add_foreign_key "stat_connections", "podcasts"
  add_foreign_key "stat_connections", "shows", on_delete: :nullify
  add_foreign_key "stat_connections", "users", on_delete: :nullify
  add_foreign_key "stat_readings", "podcasts"
  add_foreign_key "subscriptions", "users"
  add_foreign_key "waitlist_entries", "users"
end
