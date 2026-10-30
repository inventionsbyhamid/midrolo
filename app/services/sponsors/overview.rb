module Sponsors
  # The admin dashboard's sponsor detection panel: how much has been found, what's waiting for a scan, and the latest
  # reads. The catalog LLM budget it spends from is the dashboard's "Today, catalog" meter (Llm::Budget.usage).
  class Overview
    LATEST = 10

    def mentions = @mentions ||= SponsorMention.count

    def brands = @brands ||= Brand.where("sponsor_mentions_count > 0").count

    def podcasts = @podcasts ||= SponsorMention.distinct.count(:podcast_id)

    def found_today = @found_today ||= SponsorMention.where(created_at: Time.current.all_day).count

    # { "pattern" => n, "llm" => n }
    def by_detector = @by_detector ||= SponsorMention.group(:detected_by).count

    # Active podcasts' episodes due for a scan (Sponsors::Due: recent and never checked by the model), new ones and ones
    # whose check waits for the catalog budget. Older episodes are left alone and not counted.
    def waiting = @waiting ||= Due.waiting.count

    def latest
      @latest ||= SponsorMention.includes(:brand, :podcast).order(created_at: :desc, id: :desc).limit(LATEST).to_a
    end
  end
end
