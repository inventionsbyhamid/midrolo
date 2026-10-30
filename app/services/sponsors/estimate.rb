module Sponsors
  # The dry run behind `bin/rails sponsors:estimate`: what the AI sponsor scan would check for a window and a model, and
  # what it would cost, without calling the model. Eligible episodes are Sponsors::Due's (active podcasts, never checked,
  # inside the window) with at least Scan::MIN_NOTES characters of notes. A podcast's go sponsors_max_per_podcast a run,
  # ten a call.
  #
  # Tokens are estimated, priced from config/llm_pricing.yml: the instructions and schema once a call, each episode's
  # notes at CHARS_PER_TOKEN (up to Notes::MODEL_TEXT_LIMIT characters) plus its headers, OUTPUT_TOKENS_PER_EPISODE out.
  # New episodes a day come from each active podcast's cadence (weekly when the feed didn't show one); each usually
  # arrives alone after a feed read, so each is priced as a call of its own.
  class Estimate
    CHARS_PER_TOKEN = 4
    # The show line and the request's framing, once a call.
    CALL_OVERHEAD_TOKENS = 100
    EPISODE_OVERHEAD_TOKENS = 20
    OUTPUT_TOKENS_PER_EPISODE = 40
    DEFAULT_CADENCE_DAYS = 7

    Result = Data.define(:days, :model, :podcasts, :episodes, :calls, :input_tokens, :output_tokens, :cost_usd,
                         :new_per_day, :per_day_usd) do
      def per_episode_usd = episodes.positive? ? cost_usd / episodes : 0

      def lines
        [ "Sponsor scan dry run, no AI calls: #{model}, episodes from the last #{days} days on active podcasts",
          "Eligible: #{episodes} #{'episode'.pluralize(episodes)} on #{podcasts} #{'podcast'.pluralize(podcasts)}, " \
          "#{calls} #{'call'.pluralize(calls)}",
          "Tokens: about #{input_tokens} in, #{output_tokens} out",
          format("Cost: about $%.2f (about $%.5f an episode)", cost_usd, per_episode_usd),
          format("New episodes: about %.0f a day, about $%.2f a day", new_per_day, per_day_usd) ]
      end
    end

    def self.call(days: Due.window_days, model: LlmCheck.model) = new(days, model).call

    def initialize(days, model)
      @days = days.to_i
      @model = model.to_s
      Llm::Pricing.ensure_known!(@model)
    end

    def call
      rows = Due.waiting(days: @days).where("LENGTH(episodes.description) >= ?", Scan::MIN_NOTES).group(:podcast_id)
                .pluck(:podcast_id, Arel.sql("COUNT(*)"), Arel.sql("SUM(LEAST(LENGTH(episodes.description), #{Notes::MODEL_TEXT_LIMIT}))"))
      episodes = rows.sum { |_, count, _| count }
      chars = rows.sum { |_, _, length| length.to_i }
      calls = rows.sum { |_, count, _| calls_for(count) }
      input = (calls * call_tokens) + (episodes * EPISODE_OVERHEAD_TOKENS) + (chars / CHARS_PER_TOKEN)
      output = episodes * OUTPUT_TOKENS_PER_EPISODE
      new_per_day = Podcast.active.pluck(:cadence_days).sum { |days| 1.0 / (days.to_i.positive? ? days : DEFAULT_CADENCE_DAYS) }
      Result.new(days: @days, model: @model, podcasts: rows.size, episodes: episodes, calls: calls, input_tokens: input,
                 output_tokens: output, cost_usd: cost(input, output), new_per_day: new_per_day,
                 per_day_usd: new_per_day * one_episode_usd(episodes.positive? ? chars / episodes : Notes::MODEL_TEXT_LIMIT / 2))
    end

    private

    # Calls for one podcast's count of due episodes: max_per_podcast a run, ten a call.
    def calls_for(count)
      per_run = Due.max_per_podcast
      runs, rest = count.divmod(per_run)
      (runs * per_run.fdiv(LlmCheck::MAX_EPISODES).ceil) + rest.fdiv(LlmCheck::MAX_EPISODES).ceil
    end

    def call_tokens
      ((LlmCheck::INSTRUCTIONS.length + LlmCheck::SCHEMA.to_json.length) / CHARS_PER_TOKEN) + CALL_OVERHEAD_TOKENS
    end

    def one_episode_usd(chars)
      cost(call_tokens + EPISODE_OVERHEAD_TOKENS + (chars / CHARS_PER_TOKEN), OUTPUT_TOKENS_PER_EPISODE)
    end

    def cost(input, output) = Llm::Pricing.cost_usd(model: @model, input: input, output: output)
  end
end
