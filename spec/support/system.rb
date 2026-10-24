require "capybara/cuprite"

# System specs drive headless Chrome over CDP (Cuprite), no chromedriver. SwiftShader stands in for a GPU so
# MapLibre gets a WebGL context in headless Chrome.
RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :cuprite, screen_size: [ 1400, 1000 ], options: {
      headless: ENV["HEADFUL"].blank?, process_timeout: 30, timeout: 30,
      browser_options: { "no-sandbox" => nil, "enable-unsafe-swiftshader" => nil, "use-angle" => "swiftshader" }
    }
  end
end
