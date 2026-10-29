# Podcast: feed ingest, artwork, refresh scheduling and the catalog's own queries.
# Lane L1 adds its methods here, and only here (build spec section 10), so lanes don't edit the same model file.
module Podcast::Catalog
  extend ActiveSupport::Concern
end
