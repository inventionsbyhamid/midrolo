require "rails_helper"
require Rails.root.join("db/migrate/20261030180000_add_watch_until_to_show_verifications")

# Run down and up again on the test database inside the example's transaction (Postgres rolls DDL back with it).
RSpec.describe AddWatchUntilToShowVerifications do
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    ShowVerification.reset_column_information
  end

  after { ShowVerification.reset_column_information }

  it "adds watch_until, a nullable datetime that starts empty" do
    token = ShowVerification.start_feed_token!(create(:show))

    migrate(:down)
    expect(ShowVerification.column_names).not_to include("watch_until")
    migrate(:up)

    column = ShowVerification.columns_hash.fetch("watch_until")
    expect([ column.type, column.null ]).to eq([ :datetime, true ])
    expect(token.reload.watch_until).to be_nil
  end
end
