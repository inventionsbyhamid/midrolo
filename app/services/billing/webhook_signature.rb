module Billing
  # Standard Webhooks signatures (standardwebhooks.com), as Dodo sends them: webhook-signature is an HMAC-SHA256 of
  # "webhook-id.webhook-timestamp.body" under the shared secret, and webhook-timestamp must be within 5 minutes of now,
  # so a captured webhook can't be replayed later. Adapters include this and define #webhook_secret; the Fake signs
  # with its own test secret, so specs run the very check production does.
  module WebhookSignature
    HEADERS = %w[webhook-id webhook-timestamp webhook-signature].freeze

    # Raises InvalidSignature unless raw_body was signed with webhook_secret (MissingCredentials without one).
    # Returns the event id, which the signature covers. headers: request.headers, or any Hash keyed by header name.
    def verify!(raw_body, headers)
      secret = webhook_secret.presence
      raise MissingCredentials, "#{self.class.name}: the webhook secret is not set (#{webhook_secret_name})" unless secret

      values = HEADERS.index_with { |name| headers[name].presence }
      StandardWebhooks::Webhook.new(secret).verify(raw_body.to_s, values)
      values.fetch("webhook-id")
    rescue StandardWebhooks::StandardWebhooksError, JSON::ParserError => e
      raise InvalidSignature, e.message
    end
  end
end
