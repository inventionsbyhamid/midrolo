# expect { ... }.to change(A, :count).by(1).and not_change(B, :count)
RSpec::Matchers.define_negated_matcher :not_change, :change
