# The catalog's operator tasks (build spec L1 and section 7). Run them in the worker container in production.
namespace :catalog do
  desc "Seed the catalog from Qloo's podcasts, matched to their feeds: catalog:seed[1000]"
  task :seed, [ :target ] => :environment do |_task, args|
    target = Integer((args[:target].presence || Catalog::SeedFromQloo::DEFAULT_TARGET).to_s, 10)
    abort "catalog:seed: the target must be at least 1" unless target.positive?

    result = Catalog::SeedFromQloo.call(target: target, log: ->(line) { puts "catalog:seed: #{line}" })
    puts "catalog:seed: #{result.linked} linked to Qloo; this run matched #{result.matched} (#{result.added} new), " \
         "missed #{result.missed}, read #{result.pages} pages; stopped: #{result.stopped}"
  end

  desc "Seed from Qloo a page at a time, spread over hours (Catalog::SeedStepJob): catalog:seed_paced[1000,6]"
  task :seed_paced, [ :target, :hours ] => :environment do |_task, args|
    target = Integer((args[:target].presence || Catalog::SeedFromQloo::DEFAULT_TARGET).to_s, 10)
    hours = Float((args[:hours].presence || Catalog::SeedProgress::DEFAULT_HOURS).to_s)
    abort "catalog:seed_paced: the target must be at least 1" unless target.positive?
    abort "catalog:seed_paced: the hours must be more than 0" unless hours.positive?

    start = Catalog::SeedProgress.start!(target: target, hours: hours)
    progress = start.progress
    case start.status
    when :started
      cursor = Catalog::SeedFromQloo::Cursor.from_h(progress.data["cursor"])
      resumed = cursor.offset.positive? || cursor.tag_index.to_i.positive?
      from = resumed ? " (picking up at #{Catalog::SeedFromQloo::TAGS[cursor.tag_index]}, offset #{cursor.offset})" : ""
      puts "catalog:seed_paced: started#{from}: #{progress.linked} of #{target} linked to Qloo now; the first page is queued, " \
           "then one about every #{(progress.interval / 60.0).round} minutes, aiming to end by " \
           "#{progress.finish_by.utc.strftime('%b %-d %H:%M')} UTC. Watch /admin (Catalog)."
    when :running
      puts "catalog:seed_paced: a paced seed is running already (#{progress.pages} pages read, #{progress.linked} linked, " \
           "next page #{progress.next_run_at&.utc&.strftime('%b %-d %H:%M')} UTC); nothing started"
    when :reached
      puts "catalog:seed_paced: #{Podcast.where.not(qloo_entity_id: nil).count} podcasts are linked to Qloo already, " \
           "at least the target of #{target}; nothing started"
    end
  end

  desc "Stop the paced seed after the page it is on"
  task seed_stop: :environment do
    puts(Catalog::SeedProgress.stop! ? "catalog:seed_stop: stopped" : "catalog:seed_stop: no paced seed is running")
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
