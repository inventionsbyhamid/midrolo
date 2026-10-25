module Samples
  # rake samples:generate (R78): one full agent report per samples.yml entry, run inline through GenerateReportJob
  # under the samples owner, in the sample spend bucket. A slug that already has a done report is skipped unless
  # force; with force the new report replaces the old one only once it's done, so a failed run leaves the old sample up.
  # A sample that fails prints why, and the next one runs anyway.
  class Generate
    Result = Data.define(:slug, :outcome, :message) # outcome: :done, :skipped or :failed
    # The directory couldn't find the sample's show; the message says why, in ShowLookup's words.
    class ShowNotFound < StandardError; end

    def self.call(...) = new(...).call

    def initialize(force: false, entries: Samples.entries, io: $stdout)
      @force = force
      @entries = entries
      @io = io
    end

    def call = @entries.map { |entry| generate(entry.to_h.symbolize_keys) }

    private

    def generate(entry)
      slug = entry.fetch(:slug).to_s
      current = Report.find_by(sample_slug: slug)
      return finish(slug, :skipped, "already done (report #{current.id}); FORCE=1 runs it again") if current&.done? && !@force

      show = show_for(entry.fetch(:directory_id))
      report = run(show)
      return finish(slug, :failed, failure_detail(report)) unless report.done?

      publish(report, slug, replacing: current)
      finish(slug, :done, "#{show.title}, #{report.sponsor_matches.count} matches, $#{format('%.2f', report.cost_usd)}")
    rescue ShowNotFound => e
      finish(slug, :failed, e.message)
    rescue StandardError => e
      finish(slug, :failed, "#{e.class}: #{e.message}")
    end

    def owner
      @owner ||= User.find_or_create_by!(email: User::SAMPLES_EMAIL, provider: nil, uid: nil) do |user|
        user.name = "#{APP_NAME} samples"
      end
    end

    # The owner's copy of the show, refreshed from the directory. A run that died midway can't block the next one.
    def show_for(directory_id)
      lookup = ShowLookup.call(directory_id: directory_id)
      raise ShowNotFound, lookup.error unless lookup.ok?

      show = owner.shows.find_or_initialize_by(directory_id: lookup.attributes.fetch(:directory_id))
      show.update!(lookup.attributes)
      show.reports.active.find_each(&:mark_failed!)
      show
    end

    def run(show)
      report = show.reports.create!(kind: "agent", status: "queued", spend_bucket: "sample")
      GenerateReportJob.perform_now(report.id)
      report.reload
    end

    # The new report takes the slug and the one it replaces goes (its spend entries stay, unlinked). The slug index is
    # unique, so the old report lets go of it first.
    def publish(report, slug, replacing:)
      Report.transaction do
        replacing&.update!(sample_slug: nil)
        report.update!(sample_slug: slug)
        replacing&.destroy!
      end
    end

    # Why a run didn't finish: its status and error message, the last agent step that errored, and where the log is.
    def failure_detail(report)
      step = report.agent_steps.where(status: "error").last
      [ "the report ended #{report.status}: #{report.error_message.presence || 'no error message'}",
        ("last failed step: #{step.label}#{" (#{step.output_summary})" if step.output_summary.present?}" if step),
        "see log/#{Rails.env}.log" ].compact.join("; ")
    end

    def finish(slug, outcome, message)
      @io.puts "#{slug}: #{outcome} — #{message}"
      Result.new(slug: slug, outcome: outcome, message: message)
    end
  end
end
