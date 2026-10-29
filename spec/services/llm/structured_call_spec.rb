require "rails_helper"

RSpec.describe Llm::StructuredCall do
  let(:user) { create(:user, judge: true) }
  let(:schema) do
    { type: "object", properties: { subject: { type: "string" } }, required: [ "subject" ], additionalProperties: false }
  end

  def call
    described_class.call(model: "deepseek/deepseek-v4.1-flash", schema: schema, instructions: "Be brief.", prompt: "Write", user: user)
  end

  context "when live" do
    before do
      allow(Llm).to receive(:mode).and_return(:live)
      @old_key = RubyLLM.config.openrouter_api_key
      RubyLLM.config.openrouter_api_key = "test-key"
      AppSettings.set(:judge_reserve_usd, 5)
      AppSettings.set(:promo_budget_usd, 10)
    end

    after { RubyLLM.config.openrouter_api_key = @old_key }

    it "returns parsed JSON, records one spend entry and sends no temperature" do
      RubyLLM::Test.stub_response({ subject: "Hi" })
      expect { @result = call }.to change(SpendEntry, :count).by(1)
      expect(@result).to eq("subject" => "Hi")
      expect(SpendEntry.last).to have_attributes(bucket: "judge", user_id: user.id, model: "deepseek/deepseek-v4.1-flash")
      expect(RubyLLM::Test.last_request.to_s).not_to include("temperature")
      expect(RubyLLM::Test.last_request.kwargs.to_s).to include('data_collection: "deny"')
    end

    it "thinks at low effort" do
      RubyLLM::Test.stub_response({ subject: "Hi" })
      chat = RubyLLM.chat(model: "deepseek/deepseek-v4.1-flash", provider: :openrouter)
      allow(RubyLLM).to receive(:chat).and_return(chat)
      allow(chat).to receive(:with_thinking).and_call_original
      call
      expect(chat).to have_received(:with_thinking).with(effort: :low)
    end

    it "raises UnknownModel before any request for an unpriced model" do
      RubyLLM::Test.stub_response({ subject: "Hi" })
      expect do
        described_class.call(model: "deepseek/deepseek-v4.1-flash-typo", schema: schema, instructions: "x", prompt: "y", user: user)
      end.to raise_error(Llm::UnknownModel)
      expect(RubyLLM::Test.requests).to be_empty
      expect(SpendEntry.count).to eq(0)
    end

    it "raises BudgetExceeded without calling the model when not allowed" do
      AppSettings.set(:runs_paused, true)
      RubyLLM::Test.stub_response({ subject: "Hi" })
      expect { call }.to raise_error(Llm::BudgetExceeded)
      expect(RubyLLM::Test.requests).to be_empty
    end

    it "raises BudgetExceeded for a free user" do
      expect do
        described_class.call(model: "deepseek/deepseek-v4.1-flash", schema: schema, instructions: "x", prompt: "y", user: create(:user))
      end.to raise_error(Llm::BudgetExceeded)
    end
  end

  it "raises FakeModeUnsupported in fake mode without calling RubyLLM" do
    allow(Llm).to receive(:mode).and_return(:fake)
    expect { call }.to raise_error(Llm::FakeModeUnsupported)
    expect(RubyLLM::Test.requests).to be_empty
  end
end
