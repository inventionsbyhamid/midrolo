require "rails_helper"

# The docs a judge, a user and an operator read (Task 22): the README, how we use Qloo, the Devpost text, the live pitch
# and the submission checklist. Their dashes and hyphens are checked with the app's copy, in spec/copy/no_dashes_spec.rb.
RSpec.describe "Docs" do
  def doc(path) = Rails.root.join(path).read

  it "has a README with local setup that works in demo mode, and links to deploy and Qloo docs" do
    readme = doc("README.md")

    expect(readme).to include("## Local setup", "demo mode")
    expect(readme).to include("docs/deploy.md", "docs/how-we-use-qloo.md", ".env.example")
    expect(readme).to include("```mermaid")
    expect(readme).to include("AGPL-3.0")
  end

  # Three endpoints in use, /v2/insights with five filter.type values, and compare (built, off by default: R105).
  it "names every Qloo endpoint and insights type the app uses in how-we-use-qloo.md" do
    qloo = doc("docs/how-we-use-qloo.md")

    %w[/search /v2/tags /v2/insights /v2/analysis/compare].each do |endpoint|
      expect(qloo).to include("`#{endpoint}`"), "how-we-use-qloo.md doesn't mention #{endpoint}"
    end
    %w[urn:entity:brand urn:entity:podcast urn:tag urn:demographics urn:heatmap].each do |type|
      expect(qloo).to include("filter.type=#{type}"), "how-we-use-qloo.md doesn't mention filter.type=#{type}"
    end
  end

  # Addendum 5: the walkthrough is built from the synthetic fixtures with their entity ids masked, and no real looking
  # Qloo entity id (a UUID) appears in the Qloo write ups.
  it "masks entity ids in the Qloo write ups and says what a result does not establish" do
    %w[docs/how-we-use-qloo.md docs/devpost.md].each do |path|
      expect(doc(path)).not_to match(/SYN-(?:POD|BRAND)-\d+/), "#{path} shows a fixture entity id"
      expect(doc(path)).not_to match(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/), "#{path} shows an entity UUID"
    end
    expect(doc("docs/how-we-use-qloo.md")).to include("## Limitations", "does not establish")
  end

  it "has the Devpost sections and testing instructions for the open trial (R151)" do
    devpost = doc("docs/devpost.md")

    [ "## Inspiration", "## What it does", "## How we built it", "## Challenges we ran into",
      "## Accomplishments that we're proud of", "## What we learned", "## What's next", "## Testing instructions" ]
      .each { |heading| expect(devpost).to include(heading), "devpost.md lacks #{heading}" }
    expect(devpost).to include("3 shows", "waitlist", "sample media kit")
    expect(devpost).not_to include("JUDGE_CODE", "Judge code")
  end

  it "has a live pitch, a demo script and Q&A on the four likely questions" do
    pitch = doc("docs/pitch.md")

    expect(pitch).to include("## The 3 minute pitch", "## Demo script", "## Q&A")
    %w[business\ model Qloo accuracy competition].each { |topic| expect(pitch).to match(/^###.*#{topic}/i) }
  end

  it "has a submission checklist" do
    expect(doc("docs/judging.md")).to include("- [ ]")
  end

  # Addendum 2: the design doc keeps up with the build (R84 rate limits, R37/R79 hosting, R105 compare).
  it "describes Rails rate_limit and the Traefik hosting in docs/design.md, not Rack::Attack or a tunnel" do
    design = doc("docs/design.md")

    expect(design).not_to include("Rack::Attack")
    expect(design).not_to match(/behind a \*\*Cloudflare tunnel\*\*/)
    expect(design).to include("rate_limit", "Traefik")
  end
end
