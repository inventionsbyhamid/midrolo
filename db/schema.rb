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

ActiveRecord::Schema[8.1].define(version: 2026_10_25_020200) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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
    t.bigint "report_id", null: false
    t.integer "position", default: 0, null: false
    t.string "tool"
    t.string "label", null: false
    t.string "status", default: "running", null: false
    t.text "input_summary"
    t.text "output_summary"
    t.integer "duration_ms"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["report_id"], name: "index_agent_steps_on_report_id"
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
    t.index ["show_id"], name: "index_media_kits_on_show_id", unique: true
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
    t.index ["sponsor_match_id"], name: "index_pitches_on_sponsor_match_id"
    t.index ["sponsor_match_id"], name: "index_pitches_one_queued_per_match", unique: true, where: "((status)::text = 'queued'::text)"
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
    t.index ["sample_slug"], name: "index_reports_on_sample_slug", unique: true, where: "(sample_slug IS NOT NULL)"
    t.index ["show_id"], name: "index_reports_on_show_id"
    t.index ["show_id"], name: "index_reports_one_active_per_show", unique: true, where: "((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('running'::character varying)::text]))"
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
    t.index ["show_id", "created_at"], name: "index_show_verifications_on_show_id_and_created_at"
  end

  create_table "shows", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "directory_id"
    t.string "itunes_id"
    t.string "feed_url"
    t.string "title", null: false
    t.string "author"
    t.text "description"
    t.string "artwork_url"
    t.jsonb "categories", default: [], null: false
    t.integer "episode_count"
    t.string "language"
    t.integer "cadence_days"
    t.integer "downloads_per_episode"
    t.string "country", default: "US", null: false
    t.string "contact_email"
    t.jsonb "hints", default: {"topics" => [], "comparable_shows" => []}, null: false
    t.string "owner_email"
    t.datetime "verified_at"
    t.string "slug"
    t.string "qloo_entity_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "website"
    t.index ["slug"], name: "index_shows_on_slug", unique: true
    t.index ["user_id", "directory_id"], name: "index_shows_on_user_id_and_directory_id", unique: true, where: "(directory_id IS NOT NULL)"
    t.index ["user_id", "feed_url"], name: "index_shows_on_user_id_and_feed_url", unique: true, where: "(feed_url IS NOT NULL)"
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
    t.index ["bucket", "created_at"], name: "index_spend_entries_on_bucket_and_created_at"
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
    t.index ["report_id", "brand_entity_id"], name: "index_sponsor_matches_on_report_id_and_brand_entity_id", unique: true
    t.index ["report_id"], name: "index_sponsor_matches_on_report_id"
    t.index ["show_id"], name: "index_sponsor_matches_on_show_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email"
    t.string "name"
    t.string "avatar_url"
    t.string "provider", null: false
    t.string "uid", null: false
    t.boolean "admin", default: false, null: false
    t.boolean "judge", default: false, null: false
    t.integer "promo_reports_used", default: 0, null: false
    t.datetime "deleted_at"
    t.datetime "remember_created_at"
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "current_sign_in_at"
    t.datetime "last_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "last_sign_in_ip"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agent_steps", "reports"
  add_foreign_key "media_kits", "shows"
  add_foreign_key "pitches", "sponsor_matches", on_delete: :cascade
  add_foreign_key "reports", "shows"
  add_foreign_key "show_verifications", "shows"
  add_foreign_key "shows", "users"
  add_foreign_key "spend_entries", "reports", on_delete: :nullify
  add_foreign_key "spend_entries", "users"
  add_foreign_key "sponsor_matches", "reports"
  add_foreign_key "sponsor_matches", "shows"
end
