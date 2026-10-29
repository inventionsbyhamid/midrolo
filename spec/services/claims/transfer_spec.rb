require "rails_helper"

RSpec.describe Claims::Transfer do
  let(:podcast) { create(:podcast, :active) }
  let(:old_owner) { create(:show, podcast: podcast) }
  let(:new_user) { create(:user) }

  it "makes the new account's workspace the owner show and the old one a draft that keeps its kit" do
    old_owner.verify!(via: "email")
    create(:media_kit, :published, show: old_owner, open_to_sponsors: true)
    podcast.refresh_listing!
    expect(podcast.reload.open_to_sponsors).to be(true)

    show = described_class.call(podcast: podcast, to: new_user)

    expect(show).to be_verified
    expect(show.user).to eq(new_user)
    expect(old_owner.reload).not_to be_verified
    expect(old_owner.media_kit).to be_present
    expect(podcast.reload.owner_show).to eq(show)
    expect(podcast.open_to_sponsors).to be(false) # the new owner has no published listing yet
  end

  it "reuses the new owner's draft workspace, and claims an unclaimed podcast" do
    draft = create(:show, user: new_user, podcast: podcast)

    expect(described_class.call(podcast: podcast, to: new_user)).to eq(draft)
    expect(draft.reload).to be_verified
    expect(podcast.reload).to be_claimed
  end
end
