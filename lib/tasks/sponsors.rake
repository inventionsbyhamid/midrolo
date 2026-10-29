namespace :sponsors do
  desc "Queue a sponsor scan for podcasts with episodes not scanned yet (new ones, or ones whose model check waited " \
       "for the catalog budget). LIMIT podcasts at most (default 200)."
  task :scan, [ :limit ] => :environment do |_, args|
    limit = (args[:limit] || ENV["LIMIT"] || 200).to_i
    queued = Sponsors::SweepJob.new.perform(limit)
    puts "Queued sponsor scans for #{queued} #{'podcast'.pluralize(queued)}"
  end

  desc "Scan every episode of one podcast again (its slug), replacing what the model checked before"
  task :rescan, [ :slug ] => :environment do |_, args|
    podcast = Podcast.find_by_slug_or_redirect(args[:slug]) or abort("No podcast with the slug #{args[:slug].inspect}")
    ids = podcast.episodes.newest_first.limit(Sponsors::ScanJob::MAX_EPISODES).pluck(:id)
    podcast.scan_sponsors_later(ids, rescan: true)
    puts "Queued a rescan of #{ids.size} #{'episode'.pluralize(ids.size)} of #{podcast.title}"
  end
end
