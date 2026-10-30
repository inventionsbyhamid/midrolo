namespace :sponsors do
  budget_note = lambda do |queued|
    return "" if queued.positive? || Llm.fake? || Sponsors::LlmCheck.affordable?

    ". Today's catalog AI budget can't pay for a call (llm_catalog_daily_usd in /admin), so nothing was queued"
  end

  desc "Queue a sponsor scan for up to LIMIT active podcasts with episodes due (recent, never checked by the model), " \
       "the oldest podcast first: what the daily sweep runs (default 200)"
  task :scan, [ :limit ] => :environment do |_, args|
    limit = (args[:limit] || ENV["LIMIT"] || 200).to_i
    queued = Sponsors::SweepJob.new.perform(limit)
    puts "Queued sponsor scans for #{queued} #{'podcast'.pluralize(queued)}#{budget_note.call(queued)}"
  end

  desc "Queue a sponsor scan for every active podcast with episodes due (recent, never checked by the model), the " \
       "newest podcast first. Checked episodes are never sent again; older ones are left alone."
  task scan_unscanned: :environment do
    queued = Sponsors::SweepJob.queue_scans(limit: nil, newest_first: true)
    due = Sponsors::Due
    puts "Queued sponsor scans for #{queued} #{'podcast'.pluralize(queued)} (episodes from the last #{due.window_days} " \
         "days, at most #{due.max_per_podcast} per podcast a run)#{budget_note.call(queued)}"
  end

  desc "Dry run, no AI calls: the episodes the AI sponsor scan would check (active podcasts, never checked, inside the " \
       "window) and what they would cost. DAYS and MODEL default to sponsors_ai_window_days and the sponsors model"
  task :estimate, %i[days model] => :environment do |_, args|
    days = (args[:days].presence || ENV["DAYS"].presence)&.to_i || Sponsors::Due.window_days
    model = args[:model].presence || ENV["MODEL"].presence || Sponsors::LlmCheck.model
    puts Sponsors::Estimate.call(days: days, model: model).lines
  end

  desc "Recount each brand's sponsor reads (brands.sponsor_mentions_count) where deletions left it wrong"
  task recount: :environment do
    fixed = Sponsors::Recount.call
    puts "Recounted sponsor reads: #{fixed} #{'brand'.pluralize(fixed)} corrected"
  end

  desc "Admin only, on purpose: scan one podcast's newest 100 episodes again (its slug), checked ones too, replacing " \
       "what the model said before"
  task :rescan, [ :slug ] => :environment do |_, args|
    podcast = Podcast.find_by_slug_or_redirect(args[:slug]) or abort("No podcast with the slug #{args[:slug].inspect}")
    ids = podcast.episodes.newest_first.limit(Sponsors::ScanJob::MAX_EPISODES).pluck(:id)
    podcast.scan_sponsors_later(ids, rescan: true)
    puts "Queued a rescan of #{ids.size} #{'episode'.pluralize(ids.size)} of #{podcast.title}"
  end
end
