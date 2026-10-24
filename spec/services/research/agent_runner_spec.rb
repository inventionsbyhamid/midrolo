require "rails_helper"

RSpec.describe Research::AgentRunner do
  let(:user) { create(:user, judge: true) }
  let(:show) do
    create(:show, user: user, title: "The Founder's Ledger", feed_url: "fake://fake-1", categories: [ "Business", "Finance" ],
                  downloads_per_episode: 1500, hints: { comparable_shows: [ "Index Fund Mornings" ], topics: [] })
  end
  let(:report) { create(:report, show: show, kind: "agent", status: "queued", spend_bucket: "judge") }
  let(:seed_ids) { [ "fake:podcast:the-founder-s-ledger", "fake:podcast:index-fund-mornings" ] }

  before do
    Taste::Provider.reset!
    Podcasts::Directory.reset!
    allow(Llm).to receive(:mode).and_return(:live)
    @old_key = RubyLLM.config.anthropic_api_key
    RubyLLM.config.anthropic_api_key = "test-key"
  end

  after { RubyLLM.config.anthropic_api_key = @old_key }

  def call_tool(name, args = {})
    @call_id = @call_id.to_i + 1
    id = "toolu_#{@call_id}"
    RubyLLM::Message.new(role: :assistant, content: "", model: "claude-opus-5-5", input_tokens: 1000, output_tokens: 200,
                         tool_calls: { id => RubyLLM::ToolCall.new(id: id, name: name, arguments: args) })
  end

  def final_text = RubyLLM::Message.new(role: :assistant, content: "Done.", model: "claude-opus-5-5", input_tokens: 1000, output_tokens: 200)

  def playbook(save_matches: true)
    steps = [
      call_tool("read_show_feed"),
      call_tool("find_on_qloo", "names" => [ "The Founder's Ledger", "Index Fund Mornings" ], "topics" => [ "Business" ]),
      call_tool("save_taste_seeds", "entity_ids" => seed_ids, "tag_ids" => [ "urn:tag:genre:media:business" ],
                                    "profile_kind" => "direct", "sources" => { seed_ids.first => "Your show on Qloo" }),
      call_tool("build_audience_profile"),
      call_tool("find_sponsor_candidates", "categories" => [ "Finance", "Productivity" ]),
      call_tool("explain_matches", "brand_ids" => Array.new(12) { |i| "b#{i + 1}" })
    ]
    if save_matches
      steps << call_tool("save_sponsor_matches",
                         "matches" => Array.new(25) { |i| { "brand_id" => "b#{i + 1}", "reason" => "Shares finance tastes with your listeners." } })
    end
    steps + [ call_tool("save_summary", "summary" => "Your listeners are founders who love finance tools."), final_text ]
  end

  it "runs the playbook through the job: steps in order, matches, summary, spend recorded and the report done" do
    RubyLLM::Test.stub_responses(*playbook)
    expect { GenerateReportJob.perform_now(report.id) }.to change(SpendEntry, :count).by(1)
    report.reload

    expect(report.status).to eq("done")
    tools = report.agent_steps.pluck(:tool).chunk_while { |a, b| a == b }.map(&:first)
    expect(tools).to eq(%w[read_show_feed find_on_qloo save_taste_seeds taste_profile demographics heatmap
                           find_sponsor_candidates proven_sponsor_scan score_candidates explain_matches
                           save_sponsor_matches save_summary])
    expect(report.sponsor_matches.size).to eq(25)
    expect(report.summary).to eq("Your listeners are founders who love finance tools.")
    expect(report.profile_kind).to eq("direct")

    entry = SpendEntry.last
    expect(entry).to have_attributes(user_id: user.id, report_id: report.id, bucket: "judge", model: "claude-opus-5-5",
                                     input_tokens: 9000, output_tokens: 1800, kind: "llm")
    expect(entry.cost_usd).to eq(BigDecimal("0.072"))
    expect(report.cost_usd).to eq(entry.cost_usd)
    expect(RubyLLM::Test.requests.size).to eq(9)
  end

  it "fails the report when SaveSponsorMatches is never called, still recording spend" do
    RubyLLM::Test.stub_responses(*playbook(save_matches: false))
    expect { GenerateReportJob.perform_now(report.id) }.to change(SpendEntry, :count).by(1)
    expect(report.reload.status).to eq("failed")
    expect(report.summary).to be_present # saved sections are kept
  end

  it "ends needs_input when the saved seeds total fewer than 2" do
    RubyLLM::Test.stub_responses(
      call_tool("find_on_qloo", "names" => [ "The Founder's Ledger" ], "topics" => []),
      call_tool("save_taste_seeds", "entity_ids" => [ seed_ids.first ], "tag_ids" => [], "profile_kind" => "direct"),
      final_text
    )
    GenerateReportJob.perform_now(report.id)

    expect(report.reload.status).to eq("needs_input")
    expect(report.seeds["entities"].size).to eq(1)
    expect(RubyLLM::Test.requests.size).to eq(2)
    expect(SpendEntry.count).to eq(1)
  end

  it "stops at the tool-call cap" do
    allow(Llm).to receive(:agent_max_tool_calls).and_return(2)
    RubyLLM::Test.stub_responses(*playbook)
    GenerateReportJob.perform_now(report.id)

    expect(report.reload.status).to eq("failed")
    expect(report.error_message).to include("too long")
    expect(report.agent_steps.pluck(:tool).uniq).to eq(%w[read_show_feed find_on_qloo])
    expect(SpendEntry.count).to eq(1)
  end

  it "finishes with a templated summary when the cap hits after matches were saved" do
    allow(Llm).to receive(:agent_max_tool_calls).and_return(7)
    RubyLLM::Test.stub_responses(*playbook)
    GenerateReportJob.perform_now(report.id)

    expect(report.reload.status).to eq("done")
    expect(report.sponsor_matches.size).to eq(25)
    expect(report.summary).to start_with("Built from your show's own Qloo profile.")
  end

  it "fails the report and counts the auth failure when Qloo rejects the key inside a tool" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow_any_instance_of(Taste::Providers::Fake).to receive(:search).and_raise(Taste::AuthError)
    RubyLLM::Test.stub_responses(*playbook)
    expect(AppSettings).to receive(:record_taste_auth_failure!).and_call_original
    GenerateReportJob.perform_now(report.id)

    expect(report.reload).to have_attributes(status: "failed", error_message: Report::FAILURE_MESSAGE)
    expect(report.agent_steps.find_by(tool: "find_on_qloo").status).to eq("error")
    expect(SpendEntry.count).to eq(1)
  end

  it "stops after the time limit" do
    allow(Llm).to receive(:agent_max_seconds).and_return(0)
    RubyLLM::Test.stub_responses(*playbook)
    GenerateReportJob.perform_now(report.id)
    expect(report.reload.status).to eq("failed")
    expect(report.agent_steps).to be_empty
  end

  it "fails with the paused message and never calls the model when the budget says no" do
    report.update!(spend_bucket: nil)
    RubyLLM::Test.stub_responses(*playbook)
    GenerateReportJob.perform_now(report.id)

    expect(report.reload).to have_attributes(status: "failed", error_message: Research::Run::PAUSED_MESSAGE)
    expect(RubyLLM::Test.requests).to be_empty
    expect(SpendEntry.count).to eq(0)
  end

  it "builds a valid request for the agent model: tools, adaptive thinking at medium effort, caching, no temperature" do
    toolkit = Research::Toolkit.new(report)
    chat = SponsorResearchAgent.chat(toolkit: toolkit, provider: Llm.provider)
    payload = chat.ask_later("Research sponsors.").render

    expect(payload[:model]).to eq("claude-opus-5-5")
    expect(payload).not_to have_key(:temperature)
    expect(payload[:thinking]).to eq(type: "adaptive")
    expect(payload[:output_config]).to eq(effort: "medium")
    expect(payload[:cache_control]).to eq(type: "ephemeral")
    expect(payload[:tools].pluck(:name)).to eq(%w[read_show_feed find_on_qloo save_taste_seeds build_audience_profile
                                                  find_sponsor_candidates explain_matches save_sponsor_matches save_summary])
    system = payload[:system].pluck(:text).join
    expect(system).to include("save_sponsor_matches", "save_summary", "proxy")
  end
end
