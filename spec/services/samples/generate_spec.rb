require "rails_helper"

# rake samples:generate's work (R78): one agent report per config/samples.yml entry, under the samples owner.
RSpec.describe Samples::Generate do
  let(:io) { StringIO.new }
  # samples.yml names real Podcast Index shows; these runs use the demo catalog's three shows under their own slugs.
  let(:demo_entries) do
    [ { slug: "sample-one", directory_id: "fake-1" }, { slug: "sample-two", directory_id: "fake-2" },
      { slug: "sample-three", directory_id: "fake-3" } ].map(&:freeze)
  end

  before do
    Taste::Provider.reset!
    Podcasts::Directory.reset!
    allow(Samples).to receive_messages(entries: demo_entries, slugs: demo_entries.map { |entry| entry[:slug] })
  end

  def generate(**options) = described_class.call(io: io, **options)
  def samples = Report.where.not(sample_slug: nil)

  it "runs a done agent report for each samples.yml entry on the Fake providers, in the sample spend bucket" do
    expect { generate }.to change(Report, :count).by(3)

    expect(samples.pluck(:sample_slug)).to match_array(%w[sample-one sample-two sample-three])
    expect(samples.map { |report| [ report.kind, report.status, report.spend_bucket ] }.uniq).to eq([ %w[agent done sample] ])
    expect(samples.map { |report| report.show.directory_id }).to match_array(%w[fake-1 fake-2 fake-3])
    expect(samples).to all(satisfy { |report| report.sponsor_matches.any? })
    expect(io.string).to include("sample-one: done — The Founder's Ledger")
  end

  it "owns every sample through one user that has no provider or uid to sign in with" do
    generate

    owner = User.sole
    expect(owner).to have_attributes(email: "samples@midrolo.com", provider: nil, uid: nil)
    expect(samples.map { |report| report.show.user }.uniq).to eq([ owner ])
    expect(owner.active_for_authentication?).to be(false)
  end

  it "skips a slug that already has a done report, so a second run creates none" do
    generate

    expect { generate }.not_to change(Report, :count)
    expect(User.count).to eq(1)
    expect(io.string).to include("sample-one: skipped")
  end

  it "runs every sample again with force, replacing each old report with the new one on the same show" do
    generate
    before = samples.pluck(:sample_slug, :id).to_h

    generate(force: true)

    after = samples.pluck(:sample_slug, :id).to_h
    expect(after.keys).to match_array(before.keys)
    expect(after.values & before.values).to be_empty
    expect(Report.where(id: before.values)).to be_empty
    expect(Report.count).to eq(3)
    expect(Show.count).to eq(3)
  end

  it "keeps the old sample public when a forced run fails" do
    generate
    old = Report.find_by!(sample_slug: "sample-one")
    allow(Research::Run).to receive(:call).and_raise("boom")

    generate(force: true)

    expect(Report.find_by!(sample_slug: "sample-one")).to eq(old)
    expect(io.string).to include("sample-one: failed — the report ended failed: #{Report::FAILURE_MESSAGE}")
  end

  it "says which step failed and where the log is" do
    allow(Research::Run).to receive(:call) do |report|
      report.agent_steps.create!(position: 1, tool: "search_taste", label: "Finding comparable shows on Qloo…",
                                 status: "error", output_summary: "Qloo answered 429")
      raise "boom"
    end

    generate(entries: Samples.entries.first(1))

    expect(io.string).to include("sample-one: failed — the report ended failed",
                                 "last failed step: Finding comparable shows on Qloo… (Qloo answered 429)",
                                 "see log/test.log")
  end

  it "prints why a sample failed and goes on to the next one" do
    entries = [ { slug: "sample-one", directory_id: "fake-404" }, { slug: "sample-two", directory_id: "fake-2" } ]

    results = generate(entries: entries)

    expect(io.string).to include("sample-one: failed — We couldn't find that show.")
    expect(Report.find_by(sample_slug: "sample-one")).to be_nil
    expect(Report.find_by!(sample_slug: "sample-two")).to be_done
    expect(results.map { |result| [ result.slug, result.outcome ] }).to eq([ [ "sample-one", :failed ], [ "sample-two", :done ] ])
  end
end
