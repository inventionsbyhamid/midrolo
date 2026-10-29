# Brands (sponsors found in feeds, and the companies that sign up to search), the sponsor reads found in episodes, and
# the people who run a brand's account.
class CreateBrandsAndSponsorMentions < ActiveRecord::Migration[8.1]
  def change
    create_table :brands do |t|
      t.string :public_id, null: false
      t.string :slug, null: false
      t.string :name, null: false
      t.string :name_key, null: false # Research::Names.normalize(name), for Brand.resolve and Brand.find_existing
      t.string :domain # lowercase, no www, registrable part (Brand.normalize_domain)
      t.string :qloo_entity_id
      t.jsonb :categories, null: false, default: []
      t.jsonb :qloo_profile, null: false, default: {} # competitors, complementary, industries: names and ids
      t.integer :sponsor_mentions_count, null: false, default: 0
      t.datetime :verified_at
      t.timestamps
    end
    add_index :brands, :public_id, unique: true
    add_index :brands, :slug, unique: true
    add_index :brands, :domain, unique: true
    add_index :brands, :qloo_entity_id, unique: true
    add_index :brands, :name_key
    add_index :brands, :categories, using: :gin

    create_table :sponsor_mentions do |t|
      t.references :podcast, null: false, foreign_key: true, index: false # (podcast_id, published_at) below
      t.references :episode, null: false, foreign_key: true, index: false
      t.references :brand, null: false, foreign_key: true, index: false
      t.datetime :published_at # the episode's, copied so histories need no join
      t.string :promo_code
      t.string :offer # at most 160 characters
      t.string :url
      t.string :evidence # at most 240 characters
      t.string :detected_by, null: false # pattern, llm
      t.float :confidence
      t.timestamps
    end
    add_index :sponsor_mentions, %i[episode_id brand_id], unique: true
    add_index :sponsor_mentions, %i[brand_id podcast_id]
    add_index :sponsor_mentions, %i[podcast_id published_at]

    create_table :brand_members do |t|
      t.references :brand, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :role, null: false, default: "owner"
      t.datetime :verified_at
      t.string :code_digest
      t.string :code_sent_to
      t.datetime :code_expires_at
      t.integer :attempts, null: false, default: 0
      t.timestamps
    end
    add_index :brand_members, %i[brand_id user_id], unique: true
  end
end
