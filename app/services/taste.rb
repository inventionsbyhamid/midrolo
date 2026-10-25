# Vendor-neutral taste graph. Use Taste::Provider.current; never call an adapter's vendor API directly.
module Taste
  class Error < StandardError; end
  # 401 from the vendor: a bad or missing key. Only this one counts toward pausing runs.
  class AuthError < Error; end
  # 403 from the vendor: the key can't use that entity type (Qloo's hackathon guide). Optional steps skip it; it never
  # counts as an auth failure (R87).
  class Unsupported < Error; end
  # 400 from the vendor: it couldn't use the request (an unmatched location, an unknown tag).
  class BadRequest < Error; end
  # 404 from the vendor on a call where it isn't "no results".
  class NotFound < Error; end
  # 429 from the vendor that we may not retry.
  class RateLimited < Error; end
  # Our own call guard (Taste::CallGuard, R92) refused a live request before it was made: a cap is reached.
  class CallCapReached < RateLimited; end
  # 5xx, timeouts, connection failures or unparseable bodies.
  class Unavailable < Error; end
  class MissingCredentials < Error; end
end
