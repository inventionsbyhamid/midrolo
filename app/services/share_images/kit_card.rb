module ShareImages
  # A public media kit's share image: the show's title and host, its self-reported downloads per episode (with the
  # self-reported note) when the owner gave them, the audience's top taste tags (MediaKit::Content, as the kit page
  # shows them) and the show's artwork, or the mark when there is none or it can't be fetched.
  class KitCard < Card
    def initialize(kit)
      @kit = kit
      @show = kit.show
      @content = MediaKit::Content.new(kit)
    end

    def artwork? = true
    def artwork_url = Show.http_url(@show.artwork_url)

    private

    def key_parts = [ "kit", version_of(@kit), version_of(@show), version_of(@content.report) ]

    def fields
      downloads = @show.downloads_per_episode
      { label: "Media kit", title: @show.title, subline: ("Hosted by #{@show.author}" if @show.author.present?),
        stat: ([ ActiveSupport::NumberHelper.number_to_delimited(downloads), "downloads per episode" ] if downloads),
        note: ("Stats self-reported by the verified owner." if downloads),
        tags: @content.taste_tags, seed: @show.id }
    end
  end
end
