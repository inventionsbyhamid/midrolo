# True when any Fake adapter is active (drives the demo-data banner).
module DemoMode
  def self.active?
    Taste::Provider.current.is_a?(Taste::Providers::Fake) ||
      Podcasts::Directory.current.is_a?(Podcasts::Directories::Fake) ||
      Llm.mode == :fake
  end
end
