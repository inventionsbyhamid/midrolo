# Records in URLs get a random public id (R147): /shows/3f9a1c2b7d4e8a60, never /shows/1, which would leak how many
# there are and invite guessing. The database ids stay the keys everything else uses (foreign keys, Active Storage's
# record_id). Existing rows get one here, the same shape HasPublicId gives new ones (16 hex characters).
class AddPublicIds < ActiveRecord::Migration[8.1]
  TABLES = %i[shows reports sponsor_matches pitches].freeze

  def up
    TABLES.each do |table|
      add_column table, :public_id, :string
      execute <<~SQL
        UPDATE #{table} SET public_id = substr(replace(gen_random_uuid()::text, '-', ''), 1, 16) WHERE public_id IS NULL
      SQL
      change_column_null table, :public_id, false
      add_index table, :public_id, unique: true
    end
  end

  def down
    TABLES.each { |table| remove_column table, :public_id }
  end
end
