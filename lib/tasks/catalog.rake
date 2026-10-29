# The catalog's operator tasks (build spec L1 and section 7). Run them in the worker container in production.
namespace :catalog do
  desc "Seed the catalog from Qloo's podcasts, matched to their feeds: catalog:seed[1000]"
  task :seed, [ :target ] => :environment do |_task, args|
    target = Integer(args[:target].presence || Catalog::SeedFromQloo::DEFAULT_TARGET, 10)
    abort "catalog:seed: the target must be at least 1" unless target.positive?

    result = Catalog::SeedFromQloo.call(target: target, log: ->(line) { puts "catalog:seed: #{line}" })
    puts "catalog:seed: #{result.linked} linked to Qloo; this run matched #{result.matched} (#{result.added} new), " \
         "missed #{result.missed}, read #{result.pages} pages; stopped: #{result.stopped}"
  end

  desc "Queue feed reads: every podcast never read yet (low priority), then those due (as the 10 minute loop does)"
  task refresh: :environment do
    never = Podcast.where(next_fetch_at: nil).where.not(status: "removed")
    count = 0
    never.find_each do |podcast|
      podcast.ingest_later(priority: :low)
      count += 1
    end
    Catalog::RefreshDueJob.perform_now
    puts "catalog:refresh: queued #{count} never read; queued the due ones (#{Podcast.where.not(leased_until: nil).count} leased)"
  end

  desc "Add one show by RSS feed URL, Apple Podcasts link or name, and read its feed now: catalog:add[url_or_name]"
  task :add, [ :query ] => :environment do |_task, args|
    # A name with commas arrives split across the task's arguments.
    query = [ args[:query], *args.extras ].compact.join(",")
    result = Catalog::AddShow.call(query)
    abort "catalog:add: #{result.error}" unless result.ok?

    podcast = result.podcast
    puts "catalog:add: #{result.created ? 'added' : 'already in the catalog'}: #{podcast.title} (#{podcast.feed_url})"
    Catalog::IngestPodcastJob.perform_now(podcast.id)
    podcast.reload
    puts "catalog:add: #{podcast.status}, #{podcast.episode_count} episodes, indexable: #{podcast.indexable}, " \
         "slug: #{podcast.slug}#{", error: #{podcast.last_error}" if podcast.last_error}"
    result.others.each { |hit| puts "catalog:add: also found: #{hit.title} by #{hit.author} (#{hit.feed_url})" }
  end
end
