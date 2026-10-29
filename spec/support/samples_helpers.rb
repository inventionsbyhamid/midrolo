# config/samples.yml names real shows by their Podcast Index ids, which the demo catalog doesn't have. Specs that
# generate a sample use the first sample's slug on a demo show instead.
module SamplesHelpers
  def demo_sample_entry = Samples.entries.first.merge(directory_id: "fake-1")

  def first_sample_slug = Samples.slugs.first
end

RSpec.configure do |config|
  config.include SamplesHelpers
end
