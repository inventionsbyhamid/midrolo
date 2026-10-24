class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV.fetch("MAIL_FROM", "#{APP_NAME} <hello@midrolo.com>") }
  layout "mailer"
end
