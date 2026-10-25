require "rails_helper"

# The docs a judge, a user and an operator read (Task 22): the README, how we use Qloo, the Devpost text, the live pitch
# and the submission checklist. The copy rules (R97) bind them like the app's copy: no em dash and no en dash.
RSpec.describe "Docs" do
  def doc(path) = Rails.root.join(path).read

  def dash = /[\u2014\u2013]/ # em dash, en dash

  def reader_docs = %w[README.md docs/how-we-use-qloo.md docs/devpost.md docs/pitch.md docs/judging.md]

  it "has a README with local setup that works in demo mode, and links to deploy and Qloo docs" do
    readme = doc("README.md")

    expect(readme).to include("## Local setup", "demo mode")
    expect(readme).to include("docs/deploy.md", "docs/how-we-use-qloo.md", ".env.example")
    expect(readme).to include("```mermaid")
    expect(readme).to include("AGPL-3.0")
  end

  it "names every Qloo endpoint family the app uses in how-we-use-qloo.md" do
    qloo = doc("docs/how-we-use-qloo.md")

    %w[/search /v2/tags /v2/insights urn:demographics urn:heatmap /v2/analysis/compare].each do |endpoint|
      expect(qloo).to include(endpoint), "how-we-use-qloo.md doesn't mention #{endpoint}"
    end
  end

  # Addendum 5: the walkthrough is built from the synthetic fixtures with their entity ids masked.
  it "masks the fixture entity ids in the walkthrough and says what a result does not establish" do
    qloo = doc("docs/how-we-use-qloo.md")

    expect(qloo).not_to match(/SYN-(?:POD|BRAND)-\d+/)
    expect(qloo).to include("## Limitations", "does not establish")
  end

  it "has the Devpost sections and testing instructions with the judge code placeholder" do
    devpost = doc("docs/devpost.md")

    [ "## Inspiration", "## What it does", "## How we built it", "## Challenges we ran into",
      "## Accomplishments that we're proud of", "## What we learned", "## What's next", "## Testing instructions" ]
      .each { |heading| expect(devpost).to include(heading), "devpost.md lacks #{heading}" }
    expect(devpost).to include("<<JUDGE_CODE>>", "waitlist")
  end

  it "has a live pitch, a demo script and Q&A on the four likely questions" do
    pitch = doc("docs/pitch.md")

    expect(pitch).to include("## The 3 minute pitch", "## Demo script", "## Q&A")
    %w[business\ model Qloo accuracy competition].each { |topic| expect(pitch).to match(/^###.*#{topic}/i) }
  end

  it "has a submission checklist" do
    expect(doc("docs/judging.md")).to include("- [ ]")
  end

  it "keeps em and en dashes out of every doc a reader sees" do
    offenders = reader_docs.flat_map do |path|
      doc(path).each_line.with_index(1).filter_map { |line, n| "#{path}:#{n}: #{line.strip}" if line.match?(dash) }
    end

    expect(offenders).to be_empty, "Dashes in docs:\n#{offenders.join("\n")}"
  end

  # Addendum 2: the design doc keeps up with the build (R84 rate limits, R37/R79 hosting, R105 compare).
  it "describes Rails rate_limit and the Traefik hosting in docs/design.md, not Rack::Attack or a tunnel" do
    design = doc("docs/design.md")

    expect(design).not_to include("Rack::Attack")
    expect(design).not_to match(/behind a \*\*Cloudflare tunnel\*\*/)
    expect(design).to include("rate_limit", "Traefik")
  end
end
