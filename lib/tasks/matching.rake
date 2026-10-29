namespace :matching do
  desc "Find the shows with a similar audience (build spec L8) for done sample reports that ran before that step: one " \
       "Qloo call each, matched to the catalog. Samples that have them are skipped."
  task similar_backfill: :environment do
    Samples.reports.each do |report|
      shows = ->(count) { "#{count} #{'show'.pluralize(count)}" }
      next puts("#{report.sample_slug}: already has #{shows.(report.similar_podcasts.size)}") if report.similar_podcasts.present?

      entries = Research::SimilarPodcasts.backfill(report)
      puts "#{report.sample_slug}: #{entries ? shows.(entries.size) : 'skipped (see its last research step)'}"
    end
  end
end
