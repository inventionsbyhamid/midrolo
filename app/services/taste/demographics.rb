module Taste
  # Both hashes map bucket => lean (relative skew, roughly -1..1). Never percentages.
  Demographics = Data.define(:age, :gender)
end
