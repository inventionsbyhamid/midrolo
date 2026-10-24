namespace :eval do
  desc "Run the research agent eval: one full report per show in config/eval_shows.yml (or the given file)"
  task :run, [ :path ] => :environment do |_task, args|
    path = args[:path].presence || ENV["EVAL_FILE"].presence || Research::Evaluation::DEFAULT_PATH
    results = Research::Evaluation.new(path: path).run
    abort("Eval failed: #{results.reject(&:passed?).map(&:label).join('; ')}") unless results.all?(&:passed?)
  end
end
