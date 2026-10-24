# Vendor-neutral taste graph. Use Taste::Provider.current; never call an adapter's vendor API directly.
module Taste
  class Error < StandardError; end
  # 401 / 403 from the vendor: bad or missing key.
  class AuthError < Error; end
  # 429 after retries.
  class RateLimited < Error; end
  # 5xx, timeouts, connection failures or unparseable bodies.
  class Unavailable < Error; end
  class MissingCredentials < Error; end
end
