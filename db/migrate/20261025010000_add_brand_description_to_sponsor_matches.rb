class AddBrandDescriptionToSponsorMatches < ActiveRecord::Migration[8.1]
  def change
    # The brand's Qloo description (R52), for the pitch writer only: third-party text, never rendered on a card.
    add_column :sponsor_matches, :brand_description, :text
  end
end
