require "rails_helper"

# Blocking a brand closes what's running between it and the podcast and stops new requests until unblocked.
RSpec.describe Conversations::BlockBrand do
  let(:podcast) { claimed_podcast }
  let(:membership) { brand_member_for }
  let(:brand) { membership.brand }

  it "closes the brand's running conversations with the podcast, once, and unblocks" do
    conversation = start_request(podcast, membership)
    elsewhere = start_request(create(:podcast), membership)

    2.times { described_class.block(podcast: podcast, brand: brand) }

    expect(Block.where(podcast: podcast, brand: brand).count).to eq(1)
    expect(conversation.reload).to be_closed
    expect(elsewhere.reload).to be_waiting_for_claim
    expect(Conversations::Start.call(podcast: podcast, membership: membership, form: request_form).error)
      .to eq(Conversations::Start::BLOCKED)

    described_class.unblock(podcast: podcast, brand: brand)
    expect(described_class.blocked?(podcast_id: podcast.id, brand_id: brand.id)).to be(false)
    expect(Conversations::Start.call(podcast: podcast, membership: membership, form: request_form)).to be_ok
  end
end
