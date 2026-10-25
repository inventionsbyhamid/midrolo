module Research
  # Names heatmap points (R106). Qloo's heatmap answers a geohash grid with no place names, so a point takes the name of
  # the nearest metro in config/world_metros.yml when it lies within MAX_KM, else none. No call is made; the report's
  # Top places then sum affinity by these names (ReportsHelper#top_places).
  module Places
    MAX_KM = 75
    EARTH_RADIUS_KM = 6371.0
    Metro = Data.define(:name, :lat, :lng)

    module_function

    def metros
      @metros ||= Rails.application.config_for(:world_metros).values.flatten(1).map do |name, lat, lng|
        Metro.new(name: name.to_s, lat: Float(lat), lng: Float(lng))
      end.freeze
    end

    # The nearest metro's name within MAX_KM of the point, or nil.
    def name_for(lat, lng)
      return nil if lat.nil? || lng.nil?

      metro, km = metros.map { |m| [ m, km_between(lat, lng, m.lat, m.lng) ] }.min_by(&:last)
      metro.name if metro && km <= MAX_KM
    end

    # Great circle distance (haversine).
    def km_between(lat1, lng1, lat2, lng2)
      rad = Math::PI / 180
      dlat = (lat2 - lat1) * rad
      dlng = (lng2 - lng1) * rad
      a = Math.sin(dlat / 2)**2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dlng / 2)**2
      2 * EARTH_RADIUS_KM * Math.asin(Math.sqrt(a))
    end
  end
end
