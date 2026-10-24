# Resend delivers production mail (config.action_mailer.delivery_method = :resend in production.rb). Without a key,
# Resend::Mailer raises as soon as a message is sent, and raise_delivery_errors surfaces that in the failed job.
Resend.api_key = ENV["RESEND_API_KEY"]
