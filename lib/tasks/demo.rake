namespace :demo do
  desc "Make or refresh the demo show (config/demo_show.yml): a fictional podcast owned and verified by an admin, " \
       "with a published listing, for trying Request a spot. DEMO_OWNER_EMAIL picks the owner account; unset means " \
       "the first admin. Safe to run again."
  task setup: :environment do
    podcast = Claims::DemoSetup.call(owner_email: ENV["DEMO_OWNER_EMAIL"])
    url_options = Rails.application.config.action_mailer.default_url_options || {}
    base = Rails.application.routes.url_helpers.root_url(**url_options).delete_suffix("/")
    puts "Demo show ready: #{base}/podcasts/#{podcast.slug} (owner #{podcast.owner_show.user.email})"
  rescue Claims::DemoSetup::NoOwner => e
    abort("demo:setup: #{e.message}")
  end
end
