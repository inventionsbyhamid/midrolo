namespace :samples do
  desc "Run the public sample reports in config/samples.yml (a full agent report each, in the sample spend bucket). " \
       "Skips samples that are already done; FORCE=1 runs them all again."
  task generate: :environment do
    results = Samples::Generate.call(force: ENV["FORCE"] == "1")
    counts = results.map(&:outcome).tally
    puts "#{counts.fetch(:done, 0)} done, #{counts.fetch(:skipped, 0)} skipped, #{counts.fetch(:failed, 0)} failed"

    failed = results.select { |result| result.outcome == :failed }
    abort("Samples failed: #{failed.map(&:slug).join(', ')}") if failed.any?
  end
end
