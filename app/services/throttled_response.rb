# The 429 Rack::Attack sends (config/initializers/rack_attack.rb, R69), shaped for whoever asked: a Turbo Stream
# request gets a stream that swaps the page's flash for MESSAGE, a Turbo Frame request gets MESSAGE inside its frame,
# and anything else gets the static public/429.html. Each carries Retry-After: the seconds until the throttle's
# window ends.
class ThrottledResponse
  MESSAGE = "Too many requests — try again in a few minutes.".freeze
  STATUS = 429

  def self.call(request) = new(request).to_rack

  def initialize(request)
    @request = request
  end

  def to_rack
    if turbo_stream?
      respond("text/vnd.turbo-stream.html", flash_stream)
    elsif (frame = @request.get_header("HTTP_TURBO_FRAME")).present?
      respond("text/html", frame_with_message(frame))
    else
      respond("text/html", Rails.public_path.join("429.html").read)
    end
  end

  private

  def respond(content_type, body)
    [ STATUS, { "content-type" => "#{content_type}; charset=utf-8", "retry-after" => retry_after.to_s }, [ body ] ]
  end

  def retry_after
    match = @request.env["rack.attack.match_data"]
    match[:period] - (match[:epoch_time] % match[:period])
  end

  def turbo_stream? = @request.get_header("HTTP_ACCEPT").to_s.include?("text/vnd.turbo-stream.html")

  def flash_stream
    flash = ApplicationController.render(partial: "components/flash", locals: { messages: { "alert" => MESSAGE } })
    %(<turbo-stream action="replace" target="flash"><template>#{flash}</template></turbo-stream>)
  end

  def frame_with_message(frame)
    message = %(<p class="flash flash-alert" role="alert">#{ERB::Util.html_escape(MESSAGE)}</p>)
    %(<turbo-frame id="#{ERB::Util.html_escape(frame)}">#{message}</turbo-frame>)
  end
end
