require "rails_helper"

# The copy rules (R97): no em dash (—) and no en dash (–) in anything a person reads. That covers the views and mailer
# views, the locales, the public error pages and the web manifest, the strings the app's Ruby code shows people (flash
# messages, constants, helper copy), the rendered pages themselves, and the docs a judge or the user reads (README.md,
# docs/devpost.md, docs/pitch.md, docs/how-we-use-qloo.md, docs/judging.md). Exempt: code comments, ERB comments, spec descriptions, internal docs, and
# what only the agent reads (its tool descriptions and results, and the rake output). The rendered pages and those docs
# also may not carry the hyphens the rules name as unneeded.
RSpec.describe "Copy has no dashes", type: :request do
  include ActiveJob::TestHelper

  around { |example| with_billing_env { example.run } }

  def dash = /[\u2014\u2013]/ # em dash, en dash

  # Hyphenated words the copy rules write open or closed, in rendered text only (class names live in attributes).
  def unneeded_hyphens
    /\b(?:founding-member|sign-in|signed-in|mid-roll|pre-roll|post-roll|follow-up|ad-read|per-episode|re-run|self-reported)\b/i
  end

  # Words the reports and kits put plainly (R99): "loves more than most people do", "above average".
  def jargon = /\baffinit|\b(?:over|under)[ -]?index/i

  def root = Rails.root

  # "path:line: text" for each line of text with a dash.
  def dashed_lines(path, text)
    text.each_line.with_index(1).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(dash) }
  end

  # ERB and HTML comments blanked out, keeping their newlines so line numbers still point at the source.
  def without_comments(source)
    source.gsub(/<%#.*?%>|<!--.*?-->/m) { |comment| "\n" * comment.count("\n") }
  end

  # [line, text] for every string literal in a Ruby file. Comments aren't nodes and regexps are skipped.
  def string_literals(path)
    queue = [ Prism.parse_file(path.to_s).value ]
    literals = []
    while (node = queue.shift)
      next if node.is_a?(Prism::RegularExpressionNode) || node.is_a?(Prism::InterpolatedRegularExpressionNode)

      literals << [ node.location.start_line, node.unescaped ] if node.is_a?(Prism::StringNode)
      queue.concat(node.compact_child_nodes)
    end
    literals
  end

  def leaf_strings(value)
    case value
    when Hash then value.values.flat_map { |item| leaf_strings(item) }
    when Array then value.flat_map { |item| leaf_strings(item) }
    when String then [ value ]
    else []
    end
  end

  def yaml_keys(value)
    case value
    when Hash then value.keys.map(&:to_s) + value.values.flat_map { |item| yaml_keys(item) }
    when Array then value.flat_map { |item| yaml_keys(item) }
    else []
    end
  end

  describe "source" do
    it "keeps dashes out of the views and mailer views, outside ERB comments" do
      offenders = Dir[root.join("app/views/**/*")].select { |path| File.file?(path) }.flat_map do |path|
        dashed_lines(Pathname(path).relative_path_from(root), without_comments(File.read(path)))
      end

      expect(offenders).to be_empty, "Dashes in views:\n#{offenders.join("\n")}"
    end

    it "keeps dashes out of the locales, the public pages and the web manifest" do
      locales = Dir[root.join("config/locales/**/*.yml")].flat_map do |path|
        leaf_strings(YAML.load_file(path)).grep(dash).map { |text| "#{Pathname(path).relative_path_from(root)}: #{text}" }
      end
      public_pages = Dir[root.join("public/*.html")].flat_map do |path|
        dashed_lines(Pathname(path).relative_path_from(root), without_comments(File.read(path)))
      end
      manifest = leaf_strings(JSON.parse(root.join("public/site.webmanifest").read)).grep(dash)

      expect(locales + public_pages + manifest).to be_empty
    end

    # Plan names and limits reach the pricing and account pages from plans.yml; the sample pages are built from
    # samples.yml. Either file may use ERB, as config_for reads it.
    it "keeps dashes out of the plans and the sample YAML" do
      offenders = %w[config/plans.yml config/samples.yml].flat_map do |path|
        yaml = YAML.safe_load(ERB.new(root.join(path).read).result, aliases: true)
        (leaf_strings(yaml) + yaml_keys(yaml)).grep(dash).map { |text| "#{path}: #{text}" }
      end

      expect(offenders).to be_empty, "Dashes in config YAML:\n#{offenders.join("\n")}"
      expect(leaf_strings(YAML.safe_load("a:\n  b: [Pro – yearly, 1]\n  c—d: x"))).to include("Pro – yearly")
      expect(yaml_keys(YAML.safe_load("a:\n  c—d: x"))).to include("c—d")
    end

    it "keeps dashes out of the strings the app's code shows people, and the ones the agent reads" do
      # The research tools' descriptions and results are covered too: the prompt asks the agent for dash-free text,
      # so the tools speak the same way (R100). The rake task's output is for whoever runs it.
      agent_only = %w[app/services/samples/generate.rb]
      files = Dir[root.join("app/**/*.rb")].map { |path| Pathname(path).relative_path_from(root).to_s }
                                           .reject { |path| agent_only.any? { |exempt| path.start_with?(exempt) } }

      offenders = files.flat_map do |path|
        string_literals(root.join(path)).filter_map { |line, text| "#{path}:#{line}: #{text}" if text.match?(dash) }
      end

      expect(offenders).to be_empty, "Dashes in app strings:\n#{offenders.join("\n")}"
    end

    # The docs a judge or the user reads (Task 22): the README, the Devpost, pitch and Qloo write-ups, and the submission
    # checklist. Code spans count too, so a doc names files and services without the hyphens the rules call unneeded.
    it "keeps dashes and unneeded hyphens out of the docs a judge reads" do
      docs = %w[README.md docs/devpost.md docs/pitch.md docs/how-we-use-qloo.md docs/judging.md]
      offenders = docs.flat_map do |path|
        text = root.join(path).read
        hyphenated = text.each_line.with_index(1).filter_map do |line, number|
          "#{path}:#{number}: #{line.strip}" if line.match?(unneeded_hyphens)
        end
        dashed_lines(path, text) + hyphenated
      end

      expect(offenders).to be_empty, "Dashes or unneeded hyphens in docs:\n#{offenders.join("\n")}"
    end

    it "finds what it looks for" do
      expect(dashed_lines("x.erb", without_comments("<%# a — b %>\n<p>a – b</p>\n<!-- c — d -->"))).to eq([ "x.erb:2: <p>a – b</p>" ])
      path = Rails.root.join("tmp/no_dashes_probe.rb")
      path.write(%(# a comment — exempt\nA = "Copy — here"\nB = /a—b/\nC = "x \#{1} – y"\n))
      expect(string_literals(path).select { |_, text| text.match?(dash) }.map(&:first)).to eq([ 2, 4 ])
    ensure
      path&.delete
    end
  end

  describe "rendered pages" do
    let(:user) { create(:user, :subscribed) }

    # The text a person reads or hears, a line each: text nodes, the share text, and the labels held in attributes.
    def readable_lines(html)
      doc = Nokogiri::HTML(html)
      doc.css("script, style").each(&:remove)
      shared = doc.css("meta[name='description'], meta[property^='og:'], meta[name^='twitter:']").map { |meta| meta["content"] }
      labels = doc.css("[alt], [title], [aria-label], [placeholder]")
                  .flat_map { |node| %w[alt title aria-label placeholder].map { |name| node[name] } }
      buttons = doc.css("input[type='submit'], button[value]").map { |node| node["value"] }
      [ *doc.xpath("//text()").map(&:text), *shared, *labels, *buttons ].compact.map(&:squish).compact_blank
    end

    # A full agent report on the Fake providers for a show of the user's own, with a pitch written for its top match.
    def own_report
      lookup = ShowLookup.call(directory_id: "fake-2")
      show = user.shows.create!(lookup.attributes.merge(downloads_per_episode: 1500))
      report = show.reports.create!(kind: "agent", status: "queued", spend_bucket: "paid")
      GenerateReportJob.perform_now(report.id)
      report.reload
    end

    # With the blog's fixture posts (R148), so its index, a post and the header and footer's Blog link are read too.
    it "renders the public and signed-in pages without a dash or an unneeded hyphen, and the reports and kit without jargon",
       :aggregate_failures, :blog_posts do
      allow(Llm).to receive(:mode).and_return(:fake)
      Taste::Provider.reset!
      Podcasts::Directory.reset!
      Samples::Generate.call(io: StringIO.new, entries: [ demo_sample_entry ])
      sample = Report.find_by!(sample_slug: first_sample_slug)

      public_paths = %W[/ /pricing /about /privacy /terms /samples /samples/#{sample.sample_slug} /users/sign_in /blog
                        /blog/finding-your-first-sponsor]
      rendered = public_paths.index_with { |path| get(path) && [ response.status, response.body ] }

      sign_in user
      report = own_report
      expect(report).to be_done
      show = report.show
      # The Snapshot report reads differently (no reasons, locked rows, the upgrade as its next step), so it is checked too.
      snapshot = show.reports.create!(kind: "snapshot", status: "queued")
      BuildSnapshotJob.perform_now(snapshot.id)
      expect(snapshot.reload).to be_done
      match = report.sponsor_matches.order(:position).first
      perform_enqueued_jobs { post sponsor_match_pitch_path(match) }
      create(:media_kit, :published, show: show)

      reports = [ show_report_path(show, report), show_report_path(show, snapshot), "/samples/#{sample.sample_slug}",
                  public_kit_path(show.reload.slug) ]
      private_paths = [ "/shows", "/shows/new", show_path(show), *reports.values_at(0, 1), sponsor_match_pitch_path(match),
                        "/pipeline", "/account", edit_show_media_kit_path(show), show_media_kit_path(show), reports.last ]
      private_paths.each { |path| rendered[path] = get(path) && [ response.status, response.body ] }

      rendered.each do |path, (status, body)|
        expect(status).to eq(200), "#{path} answered #{status}"
        lines = readable_lines(body)
        expect(lines.grep(dash).uniq).to be_empty, "#{path} shows a dash in:\n#{lines.grep(dash).uniq.join("\n")}"
        expect(lines.grep(unneeded_hyphens).uniq).to be_empty,
                                                     "#{path} shows an unneeded hyphen in:\n#{lines.grep(unneeded_hyphens).uniq.join("\n")}"
        next unless reports.include?(path)

        expect(lines.grep(jargon).uniq).to be_empty, "#{path} uses jargon in:\n#{lines.grep(jargon).uniq.join("\n")}"
      end
    end
  end
end
