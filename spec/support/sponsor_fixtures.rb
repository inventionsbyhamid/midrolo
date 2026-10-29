# Hand-written show notes in spec/fixtures/sponsors (real-world shapes, invented shows): a header of "key: value"
# lines (title, author, people, urls), "---", then the notes.
module SponsorFixtures
  Fixture = Data.define(:title, :author, :people, :urls, :notes)

  def sponsor_fixture(name)
    head, notes = Rails.root.join("spec/fixtures/sponsors/#{name}.txt").read.split("\n---\n", 2)
    meta = head.lines.to_h { |line| line.chomp.split(": ", 2) }
    Fixture.new(title: meta["title"], author: meta["author"], people: meta["people"].to_s.split(", "),
                urls: meta["urls"].to_s.split, notes: notes)
  end

  def sponsor_context(fixture)
    Sponsors::Context.new(title: fixture.title, author: fixture.author, people: fixture.people, urls: fixture.urls)
  end

  # A podcast built from a fixture, with one episode holding its notes.
  def podcast_from_fixture(name, published_at: 3.days.ago)
    fixture = sponsor_fixture(name)
    podcast = create(:podcast, :active, title: fixture.title, author: fixture.author, website: fixture.urls.first)
    fixture.people.each { |person| create(:podcast_person, podcast: podcast, name: person) }
    episode = create(:episode, podcast: podcast, title: "#{fixture.title} episode", description: fixture.notes,
                               published_at: published_at)
    [ podcast, episode ]
  end
end

RSpec.configure { |config| config.include SponsorFixtures }
