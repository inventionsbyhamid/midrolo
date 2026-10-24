module Podcasts
  # Shared Faraday setup for the podcast clients: retries (2 attempts, honoring Retry-After) and timeouts.
  module Http
    TIMEOUT = 10
    OPEN_TIMEOUT = 5

    def self.build(headers: {})
      Faraday.new(headers: headers) do |f|
        f.request :retry, max: 1, interval: 0.1, max_interval: 5, retry_statuses: [ 429, 503 ],
                          methods: %i[get], exceptions: [ Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::RetriableResponse ]
        f.options.timeout = TIMEOUT
        f.options.open_timeout = OPEN_TIMEOUT
        f.adapter Faraday.default_adapter
      end
    end
  end
end
