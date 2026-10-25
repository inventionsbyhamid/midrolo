module Billing
  # Standard Webhooks signatures (standardwebhooks.com), as Dodo sends them: webhook-signature is an HMAC-SHA256 of
  # "webhook-id.webhook-timestamp.body" under the shared secret, and webhook-timestamp must be within 5 minutes of now,
  # so a captured webhook can't be replayed later. Adapters include this and define #webhook_secret; the Fake signs
  # with its own test secret, so specs run the very check production does.
  module WebhookSignature
    HEADERS = %w[webhook-id webhook-timestamp webhook-signature].freeze
    # One entry of webhook-signature, which holds one or more separated by spaces: a version, a comma, then base64.
    SIGNATURE_ENTRY = %r{\Av\d+[a-z]?,[A-Za-z0-9+/]+={0,2}\z}

    # Raises InvalidSignature unless raw_body was signed with webhook_secret (MissingCredentials without one).
    # Returns the event id, which the signature covers. headers: request.headers, or any Hash keyed by header name.
    def verify!(raw_body, headers)
      secret = webhook_secret.presence
      raise MissingCredentials, "#{self.class.name}: the webhook secret is not set (#{webhook_secret_name})" unless secret

      values = HEADERS.index_with { |name| headers[name].presence }
      # standardwebhooks 1.1.0 crashes (nil.bytesize) on an entry with nothing after its comma, so its shape is checked
      # first; the rescue below is a backstop for any other malformed header the gem chokes on.
      raise InvalidSignature, "Malformed webhook-signature header" unless well_formed_signature?(values["webhook-signature"])

      begin
        StandardWebhooks::Webhook.new(secret).verify(raw_body.to_s, values)
      rescue NoMethodError, ArgumentError, TypeError => e
        raise InvalidSignature, "Unreadable webhook signature headers (#{e.class})"
      end
      values.fetch("webhook-id")
    rescue StandardWebhooks::StandardWebhooksError, JSON::ParserError => e
      raise InvalidSignature, e.message
    end

    private

    def well_formed_signature?(header)
      entries = header.to_s.split(" ")
      entries.any? && entries.all? { |entry| SIGNATURE_ENTRY.match?(entry) }
    end
  end
end
