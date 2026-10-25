require "rails_helper"

# config/initializers/client_ip.rb (R83): behind the proxy, the client's IP comes from X-Forwarded-For, never from a
# Forwarded header the client sent itself.
RSpec.describe "The client's IP behind the proxy" do
  it "ignores a client's Forwarded header for both Rack's ip and ActionDispatch's remote_ip" do
    app = ->(env) { [ 200, {}, [ ActionDispatch::Request.new(env).remote_ip, Rack::Request.new(env).ip ] ] }
    stack = ActionDispatch::RemoteIp.new(app, true, ActionDispatch::RemoteIp::TRUSTED_PROXIES)
    env = Rack::MockRequest.env_for("/", "REMOTE_ADDR" => "172.18.0.5", "HTTP_FORWARDED" => "for=203.0.113.7",
                                         "HTTP_X_FORWARDED_FOR" => "198.51.100.1")

    expect(stack.call(env).last).to eq([ "198.51.100.1", "198.51.100.1" ])
  end
end
