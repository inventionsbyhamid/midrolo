require "rails_helper"

# config/queue.yml (Solid Queue, as bin/jobs and the Puma plugin run it): the artwork fetch has a queue and a thread
# of its own, so a slow artwork host never holds up reports; reports have a queue and threads of their own, so a
# 6 minute agent run never holds up pitches, mail and webhooks (R133); and every job the app enqueues has a worker.
RSpec.describe "Job queues" do
  let(:config) { YAML.load(ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true) }

  def workers(env) = config.fetch(env).fetch("workers")
  def served(env) = workers(env).flat_map { |worker| Array(worker["queues"]) }

  it "runs the artwork fetch on its own queue, one thread, apart from every other job" do
    expect(FetchShareArtworkJob.new.queue_name).to eq("artwork")

    %w[development production].each do |env|
      artwork = workers(env).select { |worker| Array(worker["queues"]).include?("artwork") }
      expect(artwork.size).to eq(1), env
      expect(artwork.first).to include("queues" => [ "artwork" ], "threads" => 1)
      expect(served(env)).not_to include("*") # a catch-all worker would take artwork jobs too
    end
  end

  it "runs reports, full and Snapshot, on their own queue and threads, apart from default (R133)" do
    expect([ GenerateReportJob, BuildSnapshotJob ].map { |job| job.new.queue_name }).to eq(%w[reports reports])

    %w[development production].each do |env|
      reports = workers(env).select { |worker| Array(worker["queues"]).include?("reports") }
      expect(reports.size).to eq(1), env
      expect(reports.first["queues"]).to eq([ "reports" ])
      expect(reports.first["threads"]).to be >= 2
      default = workers(env).find { |worker| Array(worker["queues"]).include?("default") }
      expect(default["threads"]).to be >= 2
    end
  end

  it "runs the marketplace's catalog, sponsor and stats jobs on queues of their own, with few threads" do
    expect(Catalog::IngestPodcastJob.new.queue_name).to eq("catalog")
    expect([ ActiveStorage::TransformJob.new.queue_name, ActiveStorage::AnalyzeJob.new.queue_name ]).to eq(%w[artwork artwork])

    %w[development production].each do |env|
      threads = { "catalog" => 2, "sponsors" => 1, "stats" => 1 }.to_h do |queue, _|
        worker = workers(env).find { |w| Array(w["queues"]) == [ queue ] }
        [ queue, worker&.fetch("threads") ]
      end
      expect(threads).to eq("catalog" => 2, "sponsors" => 1, "stats" => 1), env
    end
  end

  # The jobs Active Storage, Turbo and Solid Queue enqueue in this app. (ActiveJob::Base.descendants would also hold
  # Mission Control's job proxies once an admin spec has loaded them.)
  let(:framework_jobs) do
    %w[ActiveStorage::AnalyzeJob ActiveStorage::PurgeJob ActiveStorage::TransformJob ActiveStorage::MirrorJob
       ActiveStorage::PreviewImageJob Turbo::Streams::BroadcastJob Turbo::Streams::ActionBroadcastJob
       Turbo::Streams::BroadcastStreamJob SolidQueue::RecurringJob].map(&:constantize)
  end

  it "has a worker for the queue of every job the app or its frameworks enqueue" do
    Rails.autoloaders.main.eager_load_dir(Rails.root.join("app/jobs").to_s)
    queues = (ApplicationJob.descendants + framework_jobs).to_h { |job| [ job.name, job.new.queue_name ] }
    # Mail delivery takes its queue from the mailer it is given.
    queues["ActionMailer::MailDeliveryJob"] =
      ActionMailer::MailDeliveryJob.new("VerificationMailer", "code", "deliver_now", args: []).queue_name

    expect(queues).to include("GenerateReportJob" => "reports", "GeneratePitchJob" => "default",
                              "ActionMailer::MailDeliveryJob" => "default",
                              "SolidQueue::RecurringJob" => "solid_queue_recurring")
    %w[development production].each do |env|
      missing = queues.reject { |_, queue| served(env).include?(queue) }
      expect(missing).to be_empty, "#{env}: no worker for #{missing}"
    end
  end
end
