# Pieces of the lifecycle emails (UserMailer). Email clients ignore stylesheets, so the styles are inline, in the app's
# ink and plum.
module MailerHelper
  BUTTON_STYLE = "display:inline-block;background:#22132b;color:#ffffff;font-weight:700;font-size:16px;" \
                 "line-height:1;text-decoration:none;padding:14px 22px;border-radius:10px;".freeze

  # The mail's one call to action: a link drawn as the app's primary button.
  def mail_button(label, url)
    tag.p(style: "margin:24px 0 8px;") do
      link_to(label, url, style: BUTTON_STYLE, data: { mail_button: true })
    end
  end

  # The quiet last line that says why this email came.
  def mail_footnote(text)
    tag.p(text, style: "margin:16px 0 0;font-size:14px;color:#5a4a63;")
  end
end
