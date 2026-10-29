# Deletes uploads nothing kept (R149): a direct upload is stored before its form is sent, so a form that failed to save
# or was never sent leaves a blob no record holds. Runs daily (config/recurring.yml); a blob gets a day, which no form
# takes. Every blob the app keeps is attached (media kit photos, and their variants through Active Storage's records).
class PurgeUnattachedBlobsJob < ApplicationJob
  queue_as :default

  KEEP_FOR = 1.day

  def perform
    stale = ActiveStorage::Blob.unattached.where(created_at: ..KEEP_FOR.ago)
    count = 0
    stale.find_each do |blob|
      blob.purge
      count += 1
    end
    Rails.logger.info("[Uploads] purged #{count} unattached uploads") if count.positive?
  end
end
