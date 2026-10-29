# The public sample reports (spec §5.1, R78): config/samples.yml names them, Samples::Generate runs each one as a full
# agent report under the samples owner (User::SAMPLES_EMAIL), and /samples shows the done ones to anyone, read-only.
module Samples
  # The spend bucket every sample run records its cost in, and how its run knows it's a sample (Research::AgentRunner).
  SPEND_BUCKET = "sample".freeze

  # [{slug:, directory_id:}], in samples.yml order. Read once per process, except in development, where an edit to
  # samples.yml shows up without a restart.
  def self.entries
    return read_entries if Rails.env.development?

    @entries ||= read_entries
  end

  def self.slugs = entries.map { |entry| entry.fetch(:slug).to_s }

  # The done sample reports with their shows, in samples.yml order. A slug the file no longer lists isn't one.
  def self.reports
    found = Report.done.where(sample_slug: slugs).includes(show: :podcast).index_by(&:sample_slug)
    slugs.filter_map { |slug| found[slug] }
  end

  # { report_id => number of sponsor matches } for reports, in one query.
  def self.match_counts(reports) = SponsorMatch.where(report_id: reports.map(&:id)).group(:report_id).count

  # The done sample at slug, with what its page shows preloaded (the share image needs only the show);
  # ActiveRecord::RecordNotFound (a 404) for anything else.
  def self.find!(slug, preload: [ { show: :podcast }, :agent_steps, :sponsor_matches ])
    slug = slug.to_s
    raise ActiveRecord::RecordNotFound, "no sample #{slug.inspect}" unless slugs.include?(slug)

    Report.done.includes(*Array.wrap(preload)).find_by!(sample_slug: slug)
  end

  def self.read_entries = Rails.application.config_for(:samples).fetch(:samples).map(&:freeze).freeze
  private_class_method :read_entries
end
