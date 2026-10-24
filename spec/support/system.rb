require "capybara/cuprite"

# System specs drive headless Chrome over CDP (Cuprite), no chromedriver. SwiftShader stands in for a GPU so
# MapLibre gets a WebGL context in headless Chrome.
RSpec.configure do |config|
  # The browser loads app/assets/builds/tailwind.css, so build it once when a run includes system specs; a stale
  # build would test yesterday's CSS.
  config.before(:suite) do
    if RSpec.world.filtered_examples.values.flatten.any? { |example| example.metadata[:type] == :system }
      system(Tailwindcss::Commands.command_env(verbose: false), *Tailwindcss::Commands.compile_command(silent: true),
             exception: true)
    end
  end

  config.before(:each, type: :system) do
    driven_by :cuprite, screen_size: [ 1400, 1000 ], options: {
      headless: ENV["HEADFUL"].blank?, process_timeout: 30, timeout: 30,
      browser_options: { "no-sandbox" => nil, "enable-unsafe-swiftshader" => nil, "use-angle" => "swiftshader" }
    }
  end
end
