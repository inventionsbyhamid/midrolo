namespace :eval do
  desc "Run the research agent eval: one full report per show in config/eval_shows.yml (or the given file). " \
       "EVAL_MODE=agent forces the agent (needs ANTHROPIC_API_KEY); EVAL_MODE=scripted forces fake LLM mode."
  task :run, [ :path ] => :environment do |_task, args|
    path = args[:path].presence || ENV["EVAL_FILE"].presence || Research::Evaluation::DEFAULT_PATH
    results = Research::Evaluation.new(path: path, mode: ENV["EVAL_MODE"]).run
    abort("Eval failed: #{results.reject(&:passed?).map(&:label).join('; ')}") unless results.all?(&:passed?)
  rescue Research::Evaluation::ModeUnavailable => e
    abort(e.message)
  end
end
