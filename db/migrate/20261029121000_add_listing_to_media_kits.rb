# The listing lives on the media kit (no listings table): whether the show is open to sponsors, for which months, who
# it's looking for, what it won't take, and whether its numbers show as bands.
class AddListingToMediaKits < ActiveRecord::Migration[8.1]
  def change
    change_table :media_kits, bulk: true do |t|
      t.boolean :open_to_sponsors, null: false, default: false
      t.jsonb :open_months, null: false, default: []
      t.text :looking_for # at most 500 characters
      t.jsonb :exclusions, null: false, default: []
      t.boolean :bands_only, null: false, default: false
    end
  end
end
