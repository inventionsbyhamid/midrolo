require "rails_helper"

RSpec.describe FitSearch::Summary do
  let(:search) { create(:fit_search, query: "Fieldnote Coffee") }
  let(:podcasts) { %w[Ledger Mornings Daily].map { |title| create(:podcast, title: title) } }
  let(:results) do
    podcasts.each_with_index.map do |podcast, index|
      create(:fit_result, fit_search: search, podcast: podcast, position: index + 1, score: 90 - index, price_fit: "within",
                          reasons: [ "Qloo ranks it ##{index + 1} of 50 podcasts." ])
    end
  end

  def facts(**overrides)
    described_class::Facts.new(**{ brand_name: "Fieldnote Coffee", found_on_qloo: true, qloo_count: 50, results: results,
                                   proof_brands: [ "Trade Coffee" ], within_budget: 1, open_count: 3, verified_count: 0 }.merge(overrides))
  end

  it "writes three plain bullets from the facts in fake LLM mode" do
    bullets, how = described_class.call(search, facts)

    expect(how).to eq(:template)
    expect(bullets).to eq([
      "Best fits for Fieldnote Coffee's audience on Qloo: Ledger, Mornings and Daily.",
      "Brands like yours already sponsor some of these shows: Trade Coffee.",
      "1 fits your budget and 3 are open to sponsors. Request a spot on the ones you like."
    ])
  end

  it "asks the cheap model on the catalog bucket when live, and cleans dashes out of its answer" do
    allow(Llm).to receive(:fake?).and_return(false)
    allow(Llm::StructuredCall).to receive(:call).and_return("bullets" => [ "One — two.", "Three.", "Four." ])

    bullets, how = described_class.call(search, facts)

    expect(how).to eq(:llm)
    expect(bullets).to eq([ "One, two.", "Three.", "Four." ])
    expect(Llm::StructuredCall).to have_received(:call)
      .with(hash_including(model: Llm.cheap_model, bucket: :catalog, fit_search: search, user: search.user,
                           prompt: a_string_including("<untrusted_feed>Fieldnote Coffee</untrusted_feed>")))
  end

  it "falls back to the template when the budget is spent or the model fails" do
    allow(Llm).to receive(:fake?).and_return(false)
    allow(Llm::StructuredCall).to receive(:call).and_raise(Llm::BudgetExceeded)
    expect(described_class.call(search, facts).last).to eq(:template)

    allow(Llm::StructuredCall).to receive(:call).and_return("bullets" => [ "Only one." ])
    expect(described_class.call(search, facts).last).to eq(:template)
  end
end
