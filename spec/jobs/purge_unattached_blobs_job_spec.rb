require "rails_helper"

RSpec.describe PurgeUnattachedBlobsJob do
  def upload(name = "cover.png") = ActiveStorage::Blob.create_and_upload!(io: file_fixture(name).open, filename: name)

  it "purges uploads nothing kept after a day, file and row, and keeps fresh and attached ones (R149)" do
    stale = travel_to(25.hours.ago) { upload }
    fresh = travel_to(23.hours.ago) { upload }
    kept = travel_to(3.days.ago) { upload }
    create(:media_kit).cover.attach(kept)

    described_class.perform_now

    expect(ActiveStorage::Blob.exists?(stale.id)).to be(false)
    expect(ActiveStorage::Blob.service.exist?(stale.key)).to be(false)
    expect(ActiveStorage::Blob.exists?(fresh.id)).to be(true)
    expect(ActiveStorage::Blob.exists?(kept.id)).to be(true)
  end
end
