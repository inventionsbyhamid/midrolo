# Rate limits count nowhere in specs (config/initializers/rate_limit_store.rb), so no example meets a 429 unless it's
# tagged :rate_limits: those count in a MemoryStore of their own, empty when the example starts.
RSpec.configure do |config|
  config.around(:each, :rate_limits) do |example|
    RATE_LIMIT_STORE.__setobj__(ActiveSupport::Cache::MemoryStore.new)
    example.run
  ensure
    RATE_LIMIT_STORE.__setobj__(ActiveSupport::Cache::NullStore.new)
  end
end
