module Research
  # The agent eval (spec §6): one full report per show in an eval file (config/eval_shows.yml), each checked
  # against expected traits and for provenance (every saved brand id came from a tool result in that run).
  # Reports run in the dev spend bucket under a dedicated eval user. Run it with bin/rails eval:run.
  #
  # mode: nil follows Llm.mode (the agent with an API key, else the scripted runner); :agent forces the agent
  # path (needs the provider's key, OPENROUTER_API_KEY by default, and overrides LLM_PROVIDER=fake for the run);
  # :scripted forces fake mode.
  class Evaluation
    DEFAULT_PATH = Rails.root.join("config/eval_shows.yml")
    MODES = %w[agent scripted].freeze

    class ModeUnavailable < StandardError; end

    Check = Data.define(:name, :pass, :detail) do
      def to_s = "#{pass ? 'PASS' : 'FAIL'} #{name} (#{detail})"
    end

    Result = Data.define(:label, :checks, :cost) do
      def passed? = checks.all?(&:pass)
    end

    def initialize(path: DEFAULT_PATH, io: $stdout, mode: nil)
      @path = path
      @io = io
      @mode = mode.presence&.to_s
      raise ArgumentError, "unknown eval mode #{@mode.inspect} (use #{MODES.join(' or ')})" if @mode && !MODES.include?(@mode)
    end

    # Runs every show, prints a block per show and a total line, and returns the Results.
    def run
      with_mode do
        @io.puts "LLM path: #{Llm.mode == :live ? "agent (#{Llm.agent_model})" : 'scripted runner (fake LLM mode)'}"
        results = shows.map { |entry| evaluate(entry) }
        passed = results.count(&:passed?)
        @io.puts "#{passed}/#{results.size} shows passed · total cost $#{format('%.4f', results.sum(&:cost))}"
        results
      end
    end

    private

    # Sets LLM_PROVIDER for the run when a mode is forced, and restores it afterwards. The original value is
    # read before anything can raise, so the ensure never clears a value that was there.
    def with_mode
      original = ENV["LLM_PROVIDER"]
      return yield unless @mode

      ENV["LLM_PROVIDER"] = @mode == "agent" ? (original == "fake" ? nil : original) : "fake"
      if @mode == "agent" && ENV[Llm.api_key_name].blank?
        raise ModeUnavailable, "EVAL_MODE=agent needs #{Llm.api_key_name}"
      end

      yield
    ensure
      ENV["LLM_PROVIDER"] = original if @mode
    end

    def shows = Array(YAML.load_file(@path)&.fetch("shows", nil))

    def evaluate(entry)
      show = show_for(entry)
      report = show.reports.create!(kind: "agent", status: "queued", spend_bucket: "dev")
      toolkit = run_report(report)
      report.reload
      result = Result.new(label: "#{entry['directory_id']} #{show.title} (report #{report.id})",
                          checks: checks(report, toolkit, entry["expect"] || {}), cost: report.cost_usd.to_d)
      print(result, report)
      result
    end

    def user
      @user ||= User.find_or_create_by!(provider: "eval", uid: "eval") do |u|
        u.name = "Eval runner"
        u.email = "eval@midrolo.local"
      end
    end

    def show_for(entry)
      lookup = ShowLookup.call(directory_id: entry.fetch("directory_id"))
      raise ArgumentError, "#{entry['directory_id']}: #{lookup.error}" unless lookup.ok?

      podcast = Podcast.find_or_create_from_lookup!(lookup.attributes.merge(source: "admin"))
      show = user.shows.find_or_initialize_by(podcast: podcast)
      show.update!(hints: entry["hints"] || {}, downloads_per_episode: entry["downloads_per_episode"])
      show.reports.active.find_each(&:mark_failed!) # an earlier eval that died mid-run
      show
    end

    # What GenerateReportJob does, inline, keeping the toolkit for the provenance check.
    def run_report(report)
      report.mark_running!
      toolkit = Run.call(report)
      report.mark_done! if report.reload.running?
      toolkit
    rescue StandardError => e
      @io.puts "  error: #{e.class}: #{e.message}"
      current = report.reload
      current.mark_failed! if current.active?
      nil
    end

    def checks(report, toolkit, expect)
      matches = report.sponsor_matches.to_a
      list = [ Check.new(name: "status", pass: report.done?, detail: report.status) ]
      if (min = expect["min_matches"])
        list << Check.new(name: "min_matches", pass: matches.size >= min.to_i, detail: "#{matches.size} saved, want #{min}+")
      end
      if (kind = expect["profile_kind"])
        list << Check.new(name: "profile_kind", pass: report.profile_kind == kind.to_s, detail: report.profile_kind.inspect)
      end
      list << category_check(matches, expect["category_any"]) if expect["category_any"]
      list << provenance_check(matches, toolkit)
    end

    def category_check(matches, wanted)
      wanted_keys = Array(wanted).map { |c| Names.normalize(c) }
      got = matches.filter_map(&:category).uniq
      Check.new(name: "category_any", pass: got.any? { |c| wanted_keys.include?(Names.normalize(c)) },
                detail: "got #{got.first(6).join(', ').presence || 'none'}")
    end

    def provenance_check(matches, toolkit)
      ids = matches.map(&:brand_entity_id)
      unseen = toolkit ? ids - toolkit.seen_entity_ids.to_a : ids
      Check.new(name: "provenance", pass: toolkit.present? && unseen.empty?,
                detail: unseen.empty? ? "#{ids.size} saved, all seen in tool results" : "unseen: #{unseen.first(5).join(', ')}")
    end

    def print(result, report)
      @io.puts result.label
      result.checks.each { |check| @io.puts "  #{check}" }
      @io.puts "  cost $#{format('%.4f', result.cost)} · #{report.taste_calls} taste calls · #{report.agent_steps.count} steps"
    end
  end
end
