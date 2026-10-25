# Rack::Attack is off in specs (config/initializers/rack_attack.rb), so a spec making many requests from 127.0.0.1
# never meets a 429. Examples tagged :rack_attack turn it on. Every example starts with an empty RATE_LIMIT_STORE, which
# Rack::Attack and the controllers' rate limits that use it (AccountsController's) count in.
RSpec.configure do |config|
  config.before { RATE_LIMIT_STORE.clear }

  config.around(:each, :rack_attack) do |example|
    Rack::Attack.enabled = true
    example.run
  ensure
    Rack::Attack.enabled = false
  end
end
