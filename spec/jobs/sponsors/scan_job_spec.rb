require "rails_helper"

RSpec.describe Sponsors::ScanJob do
  before { allow(Llm).to receive(:mode).and_return(:fake) }

  it "finds and saves the sponsor reads in a podcast's new episodes" do
    podcast, episode = podcast_from_fixture("sponsor_block")
    plain = create(:episode, podcast: podcast, description: "No sponsors this week.")

    described_class.perform_now(podcast.id, [ episode.id, plain.id ])

    expect(Sponsors::History.for(podcast).map { |row| row.brand.name }).to contain_exactly("Encord", "Notion", "LMNT", "AG1")
    expect(Brand.find_by!(domain: "drinklmnt.com")).to have_attributes(name: "LMNT", sponsor_mentions_count: 1)
    expect([ episode.reload.sponsor_scanned_at, plain.reload.sponsor_scanned_at ]).to all(be_present)
  end

  it "is idempotent, and skips episodes already scanned unless asked to rescan" do
    podcast, episode = podcast_from_fixture("host_reads")
    described_class.perform_now(podcast.id, [ episode.id ])
    allow(Sponsors::Scan).to receive(:call).and_call_original

    expect { described_class.perform_now(podcast.id, [ episode.id ]) }.not_to change(SponsorMention, :count)
    expect(Sponsors::Scan).not_to have_received(:call)

    expect { described_class.perform_now(podcast.id, [ episode.id ], rescan: true) }.not_to change(SponsorMention, :count)
    expect(Sponsors::Scan).to have_received(:call).once
    expect(Brand.where(name: %w[AG1 Shopify]).pluck(:sponsor_mentions_count)).to eq([ 1, 1 ])
  end

  it "never scans a removed podcast, a missing one, or another podcast's episodes" do
    podcast, episode = podcast_from_fixture("host_reads")
    other, = podcast_from_fixture("inline_list")
    allow(Sponsors::Scan).to receive(:call)

    described_class.perform_now(other.id, [ episode.id ])
    described_class.perform_now(0, [ episode.id ])
    podcast.update!(status: "removed")
    described_class.perform_now(podcast.id, [ episode.id ])

    expect(Sponsors::Scan).not_to have_received(:call)
  end

  it "is queued by the podcast for its unscanned episodes" do
    podcast, episode = podcast_from_fixture("host_reads")
    create(:episode, podcast: podcast, sponsor_scanned_at: 1.day.ago)

    expect { podcast.scan_sponsors_later }.to have_enqueued_job(described_class).with(podcast.id, [ episode.id ], rescan: false)
      .on_queue("sponsors").at_priority(20)
    expect { create(:podcast).scan_sponsors_later }.not_to have_enqueued_job(described_class)
  end
end
