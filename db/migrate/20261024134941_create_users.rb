class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email
      t.string :name
      t.string :avatar_url
      t.string :provider, null: false
      t.string :uid, null: false
      t.boolean :admin, null: false, default: false
      t.boolean :judge, null: false, default: false
      t.integer :promo_reports_used, null: false, default: 0
      t.datetime :deleted_at

      ## Rememberable
      t.datetime :remember_created_at

      ## Trackable
      t.integer :sign_in_count, null: false, default: 0
      t.datetime :current_sign_in_at
      t.datetime :last_sign_in_at
      t.string :current_sign_in_ip
      t.string :last_sign_in_ip

      t.timestamps
    end

    add_index :users, %i[provider uid], unique: true
    add_index :users, :email, unique: true
  end
end
