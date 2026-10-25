class CreateMediaKits < ActiveRecord::Migration[8.1]
  def change
    create_table :media_kits do |t|
      t.references :show, null: false, foreign_key: true, index: { unique: true }
      t.string :headline
      t.text :about
      # {"midroll" => 120}: only the slots the owner set; the rest come from Pricing::RateCard.
      t.jsonb :rate_card_overrides, null: false, default: {}
      # Qloo entity ids of audience brands the owner keeps off the kit.
      t.jsonb :hidden_brand_ids, null: false, default: []
      t.datetime :published_at
      t.integer :views_count, null: false, default: 0
      t.timestamps
    end
  end
end
