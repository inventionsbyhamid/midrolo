require "rails_helper"

# The brand side: conversations and messages, blocks, fit searches and results, saved podcasts.
RSpec.describe "Brand side records" do
  describe Conversation do
    it "holds one ongoing conversation per podcast and brand" do
      conversation = create(:conversation, status: "waiting_for_claim")
      expect(Conversation::STATUSES).to eq(%w[waiting_for_claim open accepted declined closed])
      expect { create(:conversation, podcast: conversation.podcast, brand: conversation.brand, status: "open") }
        .to raise_error(ActiveRecord::RecordNotUnique)

      conversation.update!(status: "declined", decline_reason: "Booked up")
      expect(create(:conversation, podcast: conversation.podcast, brand: conversation.brand)).to be_open
      expect(Conversation.ongoing.count).to eq(1)
    end

    it "keeps months tidy and has a public id" do
      conversation = create(:conversation, months: [ "2026-12", " ", "2026-12", "2027-01" ])
      expect(conversation.months).to eq(%w[2026-12 2027-01])
      expect(conversation.to_param).to eq(conversation.public_id)
    end

    it "marks when the last message came" do
      conversation = create(:conversation)
      message = create(:message, conversation: conversation)
      expect(conversation.reload.last_message_at).to eq(message.created_at)
      expect(build(:message, body: "")).not_to be_valid
      expect(build(:message, body: "m" * 4001)).not_to be_valid
    end

    it "keeps the other party's copy when an account goes" do
      conversation = create(:conversation)
      message = create(:message, conversation: conversation, user: conversation.started_by)

      conversation.started_by.destroy!
      expect(conversation.reload.started_by).to be_nil
      expect(message.reload).to have_attributes(user_id: nil, body: message.body)
    end
  end

  describe Block do
    it "blocks a brand from a podcast once" do
      block = create(:block)
      expect(build(:block, podcast: block.podcast, brand: block.brand)).not_to be_valid
    end
  end

  describe FitSearch do
    it "logs its steps through Research::StepLogger, as a report does" do
      search = create(:fit_search)
      log = Research::StepLogger.new(search)
      log.step("find_brand", "Finding the brand on Qloo…") { |step| step.output_summary = "Found it" }

      expect(search.agent_steps.pluck(:label, :status, :output_summary)).to eq([ [ "Finding the brand on Qloo…", "ok", "Found it" ] ])
      expect(search.agent_steps.first.run).to eq(search)
      expect(log.run).to eq(search)
    end

    it "counts its Qloo calls" do
      search = create(:fit_search)
      taste = Taste::Providers::Fake.new
      Research::StepLogger.new(search).step("search", "Searching…") { taste.search(query: "Notion", types: [ :brand ]) }
      expect(search.reload.taste_calls).to eq(1)
    end

    it "validates its query, status and budget, and has a public id" do
      expect(build(:fit_search, query: "")).not_to be_valid
      expect(build(:fit_search, status: "paused")).not_to be_valid
      expect(build(:fit_search, budget_cents: -1)).not_to be_valid
      search = create(:fit_search, categories: [ "Health", "", "Health" ])
      expect(search.categories).to eq([ "Health" ])
      expect(search.to_param).to eq(search.public_id)
    end

    it "goes with its user, taking its results and steps" do
      result = create(:fit_result)
      search = result.fit_search
      create(:agent_step, run: search)

      expect { search.user.destroy! }.to change(FitSearch, :count).by(-1)
                                                                  .and change(FitResult, :count).by(-1)
                                                                  .and change(AgentStep, :count).by(-1)
    end
  end

  describe FitResult do
    it "scores 0 to 100, one per search and podcast" do
      result = create(:fit_result)
      expect(build(:fit_result, fit_search: result.fit_search, podcast: result.podcast)).not_to be_valid
      expect(build(:fit_result, score: 101)).not_to be_valid
    end
  end

  describe SavedPodcast do
    it "is on a brand's list once, and stays when the user who saved it goes" do
      saved = create(:saved_podcast)
      expect(build(:saved_podcast, brand: saved.brand, podcast: saved.podcast)).not_to be_valid

      saved.user.destroy!
      expect(saved.reload.user).to be_nil
    end
  end
end
