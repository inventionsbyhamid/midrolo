# Rack::Attack is off in specs (config/initializers/rack_attack.rb), so a spec making many requests from 127.0.0.1
# never meets a 429. Examples tagged :rack_attack turn it on, over an empty store.
RSpec.configure do |config|
  config.around(:each, :rack_attack) do |example|
    Rack::Attack.reset!
    Rack::Attack.enabled = true
    example.run
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.reset!
  end
end
