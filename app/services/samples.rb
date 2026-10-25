# The public sample reports (spec §5.1, R78): config/samples.yml names them, Samples::Generate runs each one as a full
# agent report under the samples owner (User::SAMPLES_EMAIL), and /samples shows the done ones to anyone, read-only.
module Samples
  # [{slug:, directory_id:}], in samples.yml order.
  def self.entries = Rails.application.config_for(:samples).fetch(:samples)

  def self.slugs = entries.map { |entry| entry.fetch(:slug).to_s }

  # The done sample reports with their shows, in samples.yml order. A slug the file no longer lists isn't one.
  def self.reports
    found = Report.done.where(sample_slug: slugs).includes(:show).index_by(&:sample_slug)
    slugs.filter_map { |slug| found[slug] }
  end

  # The done sample at slug, with what its page shows; ActiveRecord::RecordNotFound (a 404) for anything else.
  def self.find!(slug)
    slug = slug.to_s
    raise ActiveRecord::RecordNotFound, "no sample #{slug.inspect}" unless slugs.include?(slug)

    Report.done.includes(:show, :agent_steps, :sponsor_matches).find_by!(sample_slug: slug)
  end
end
