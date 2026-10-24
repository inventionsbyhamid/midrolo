require "rails_helper"

RSpec.describe "Shows placeholders" do
  before { sign_in create(:user) }

  it "renders the index and new placeholders" do
    %w[/shows /shows/new].each do |path|
      get path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Add your show")
    end
  end
end
