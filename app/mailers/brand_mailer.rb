# Mail for the brand side (lane L6): the code that proves a member's work email (Brands::WorkEmail).
class BrandMailer < ApplicationMailer
  NAME_LIMIT = 60

  # The code is made here, while the queued email renders, so it is never stored in the job queue or logged. A request
  # that was retired (a newer address), expired or used before the job ran sends nothing.
  def work_email_code
    @member = params[:member]
    sent_to = params[:sent_to].to_s
    @brand_name = @member.brand.name.to_s.squish.truncate(NAME_LIMIT)
    @code = Brands::WorkEmail.issue_code!(@member, sent_to)
    return unless @code

    mail to: sent_to, subject: "Your #{APP_NAME} code for #{@brand_name}"
  end
end
