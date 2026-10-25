# Where the controllers' rate_limit calls count (R69, R84; the limits are listed in ApplicationController):
# Rails.cache, which is Solid Cache in production. In specs it's a NullStore, whose increment returns nil, so Rails
# never refuses a request and a spec making many requests from 127.0.0.1 never meets a 429. Examples tagged
# :rate_limits count in an empty MemoryStore instead (spec/support/rate_limits.rb). rate_limit keeps the store object
# it was given when the controller loaded, so the swap happens behind this delegator.
RATE_LIMIT_STORE = Rails.env.test? ? SimpleDelegator.new(ActiveSupport::Cache::NullStore.new) : Rails.cache
