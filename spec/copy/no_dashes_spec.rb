require "rails_helper"

# The copy rules (R97): no em dash (—) and no en dash (–) in anything a person reads. That covers the views and mailer
# views, the locales, the public error pages and the web manifest, the strings the app's Ruby code shows people (flash
# messages, constants, helper copy), and the rendered pages themselves. Exempt: code comments, ERB comments, spec
# descriptions, internal docs, and what only the agent reads (its tool descriptions and results, and the rake output).
# The rendered pages also may not carry the hyphens the rules name as unneeded.
RSpec.describe "Copy has no dashes", type: :request do
  include ActiveJob::TestHelper

  around { |example| with_billing_env { example.run } }

  def dash = /[\u2014\u2013]/ # em dash, en dash

  # Hyphenated words the copy rules write open or closed, in rendered text only (class names live in attributes).
  def unneeded_hyphens
    /\b(?:founding-member|sign-in|signed-in|mid-roll|pre-roll|post-roll|follow-up|ad-read|per-episode|re-run|self-reported)\b/i
  end

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

    it "keeps dashes out of the strings the app's code shows people" do
      # Only the agent reads the research tools' descriptions and results; the rake task's output is for whoever runs it.
      agent_only = %w[app/services/research/tools.rb app/services/research/tools/ app/services/samples/generate.rb]
      files = Dir[root.join("app/**/*.rb")].map { |path| Pathname(path).relative_path_from(root).to_s }
                                           .reject { |path| agent_only.any? { |exempt| path.start_with?(exempt) } }

      offenders = files.flat_map do |path|
        string_literals(root.join(path)).filter_map { |line, text| "#{path}:#{line}: #{text}" if text.match?(dash) }
      end

      expect(offenders).to be_empty, "Dashes in app strings:\n#{offenders.join("\n")}"
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

    it "renders the public and signed-in pages without a dash or an unneeded hyphen", :aggregate_failures do
      allow(Llm).to receive(:mode).and_return(:fake)
      Taste::Provider.reset!
      Podcasts::Directory.reset!
      Samples::Generate.call(io: StringIO.new, entries: Samples.entries.first(1))
      sample = Report.find_by!(sample_slug: "sample-one")

      public_paths = %W[/ /pricing /about /privacy /terms /samples /samples/#{sample.sample_slug} /users/sign_in]
      rendered = public_paths.index_with { |path| get(path) && [ response.status, response.body ] }

      sign_in user
      report = own_report
      expect(report).to be_done
      show = report.show
      match = report.sponsor_matches.order(:position).first
      perform_enqueued_jobs { post sponsor_match_pitch_path(match) }
      create(:media_kit, :published, show: show)

      private_paths = [ "/shows", "/shows/new", show_path(show), show_report_path(show, report), sponsor_match_pitch_path(match),
                        "/pipeline", "/account", edit_show_media_kit_path(show), show_media_kit_path(show), public_kit_path(show.reload.slug) ]
      private_paths.each { |path| rendered[path] = get(path) && [ response.status, response.body ] }

      rendered.each do |path, (status, body)|
        expect(status).to eq(200), "#{path} answered #{status}"
        lines = readable_lines(body)
        expect(lines.grep(dash).uniq).to be_empty, "#{path} shows a dash in:\n#{lines.grep(dash).uniq.join("\n")}"
        expect(lines.grep(unneeded_hyphens).uniq).to be_empty,
                                                     "#{path} shows an unneeded hyphen in:\n#{lines.grep(unneeded_hyphens).uniq.join("\n")}"
      end
    end
  end
end
