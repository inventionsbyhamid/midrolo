require "rails_helper"

# One list style in what people read (Task 20): "A, B and C" through Copy.and_list, never Rails' to_sentence, whose
# Oxford comma ("A, B, and C") the copy rules don't use. Copy.and_list itself is the one place that calls it.
RSpec.describe "List style" do
  it "joins every list in the app's code and views with Copy.and_list" do
    files = Dir[Rails.root.join("app/**/*.{rb,erb}")].reject { |path| path.end_with?("app/services/copy.rb") }
    offenders = files.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next if line.strip.start_with?("#", "<%#")

        "#{Pathname(path).relative_path_from(Rails.root)}:#{index + 1}: #{line.strip}" if line.include?("to_sentence")
      end
    end

    expect(offenders).to be_empty, "Use Copy.and_list instead of to_sentence:\n#{offenders.join("\n")}"
  end

  it "writes a template pitch's shared tastes as A, B and C" do
    show = create(:show, title: "Ledger", downloads_per_episode: 1500)
    report = create(:report, show: show, kind: "agent", status: "done")
    match = create(:sponsor_match, report: report, name: "Fieldnote Coffee",
                                   evidence: { "shared_tags" => [ "Specialty Coffee", "Remote Work", "Side Projects" ],
                                               "proven" => { "items" => [], "count" => 0 } })

    pack = Pitches::Template.call(Pitches::Inputs.new(match))

    expect(pack["body"]).to include("Specialty Coffee, Remote Work and Side Projects")
    expect(pack["follow_up"]).to include("share Specialty Coffee and Remote Work with your fans")
  end
end
