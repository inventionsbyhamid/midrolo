class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV.fetch("MAIL_FROM", "#{APP_NAME} <hello@midrolo.com>") }
  layout "mailer"
  helper BrandHelper # the PNG logo in the layout
  helper MailerHelper
end
