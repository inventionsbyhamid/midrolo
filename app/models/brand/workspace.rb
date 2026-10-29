# Brand: the brand's account side (members, verification, searches, saved shows).
# Lane L6 adds its methods here, and only here (build spec section 10), so lanes don't edit the same model file.
#
# qloo_profile is what the fit search's first step learned about the brand on Qloo (FitSearch::BrandProfile):
#   { "entity_id", "name", "fetched_at", "tags" => [{ "id", "name", "type" }], "categories" => [names],
#     "competitors" => [{ "name", "id" }], "complementary" => [{ "name", "id" }], "industries" => [names] }
# It stays inside the app (Qloo's terms): only the brand's own members see what it drives.
module Brand::Workspace
  extend ActiveSupport::Concern

  # A later search for the same brand reuses its Qloo profile for this long instead of asking Qloo again.
  QLOO_PROFILE_TTL = 7.days

  def qloo_profile_fetched_at
    Time.zone.parse(qloo_profile["fetched_at"].to_s) if qloo_profile.is_a?(Hash) && qloo_profile["fetched_at"].present?
  rescue ArgumentError
    nil
  end

  def qloo_profile_fresh?(now = Time.current)
    fetched = qloo_profile_fetched_at
    fetched.present? && fetched > now - QLOO_PROFILE_TTL && qloo_profile["entity_id"].present?
  end

  # Names Qloo gave for a profile list (:competitors or :complementary), at most limit.
  def qloo_names(list, limit: 10)
    Array(qloo_profile.is_a?(Hash) ? qloo_profile[list.to_s] : nil).filter_map { |row| row["name"].presence if row.is_a?(Hash) }
                                                                  .uniq.first(limit)
  end

  # Saves the profile, the categories it maps to, and the Qloo entity id unless another brand already holds that id
  # (unique index: that brand keeps it).
  def store_qloo_profile!(profile)
    self.qloo_profile = profile
    self.categories = (Array(categories) + Array(profile["categories"])).uniq.first(10)
    entity_id = profile["entity_id"].to_s
    if entity_id.present? && qloo_entity_id.blank? && !self.class.where.not(id: id).exists?(qloo_entity_id: entity_id)
      self.qloo_entity_id = entity_id
    end
    self.class.transaction(requires_new: true) { save! }
  rescue ActiveRecord::RecordNotUnique
    restore_attributes([ :qloo_entity_id ])
    self.class.transaction(requires_new: true) { save! }
  end

  # Set once, when the first member proves a work email at the brand's domain.
  def mark_verified!(at = Time.current)
    update!(verified_at: at) if verified_at.nil?
  end
end
