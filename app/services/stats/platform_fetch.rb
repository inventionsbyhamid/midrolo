module Stats
  # Stub (lane L5 fills it, build spec section 11): reads one connection's numbers from its platform by running
  # bin/platform-stats with the service session (ServiceSession) on stdin, and returns the parsed result: normalized
  # metrics, or { "error" => "expired" | "forbidden" | "not_found" | "failed", "message" => ... }.
  module PlatformFetch
    NOT_BUILT = { "error" => "failed", "message" => "Platform stats aren't connected yet." }.freeze

    module_function

    def call(connection) = NOT_BUILT
  end
end
