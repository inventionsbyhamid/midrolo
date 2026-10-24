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

ActiveRecord::Schema[8.1].define(version: 2026_10_24_150000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "settings", force: :cascade do |t|
    t.string "key", null: false
    t.jsonb "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_settings_on_key", unique: true
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

  add_foreign_key "spend_entries", "users"
end
