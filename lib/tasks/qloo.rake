namespace :qloo do
  desc "Live smoke test of the Qloo API (docs/live-smoke.md): at most 10 live calls, counted by the call guard, " \
       "printing shapes and counts only. Needs QLOO_API_KEY, in development or production."
  task smoke: :environment do
    result = Taste::Smoke.call
    abort("Qloo smoke did not pass.") unless result.passed?
  rescue Taste::Smoke::Refused => e
    abort(e.message)
  end
end
