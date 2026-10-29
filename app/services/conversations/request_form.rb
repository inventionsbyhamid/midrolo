module Conversations
  # The Request a spot form (podcasts/_request and conversations/new): the format, the months, a budget in whole
  # dollars and the first message. Conversations::Start turns a valid one into a conversation.
  class RequestForm
    include ActiveModel::Model
    include ActiveModel::Attributes

    BUDGET_LIMIT = 1_000_000 # dollars

    attribute :format, :string
    attribute :months, default: -> { [] }
    attribute :budget, :string
    attribute :body, :string
    # The brand's public id, when the user is a member of more than one.
    attribute :brand, :string

    validates :body, presence: true, length: { maximum: Message::BODY_LIMIT }
    validates :format, inclusion: { in: MediaKit::RATE_SLOTS.keys }, allow_blank: true
    validate :budget_is_whole_dollars
    validate :months_are_months

    LABELS = { "body" => "Message", "budget" => "Budget", "months" => "Months", "format" => "Format" }.freeze

    # Its params arrive as spot_request[...] (not "request", which reads like the controller's own request).
    def self.model_name = ActiveModel::Name.new(self, nil, "SpotRequest")

    def self.human_attribute_name(attribute, options = {}) = LABELS.fetch(attribute.to_s) { super }

    def months=(value)
      super(Array(value).map { |month| month.to_s.strip }.compact_blank.uniq.sort)
    end

    def body=(value)
      super(value.to_s.strip.presence)
    end

    def budget_cents
      dollars = budget_dollars
      dollars * 100 if dollars
    end

    def conversation_attributes = { format: format.presence, months: months, budget_cents: budget_cents }

    private

    # nil when blank; false when it isn't a whole number of dollars.
    def budget_dollars
      text = budget.to_s.strip.delete(",").delete_prefix("$")
      return nil if text.empty?

      text.match?(/\A\d{1,9}\z/) ? text.to_i : false
    end

    def budget_is_whole_dollars
      dollars = budget_dollars
      return if dollars.nil?

      if dollars == false
        errors.add(:budget, "must be a whole number of dollars")
      elsif dollars > BUDGET_LIMIT
        errors.add(:budget, "can't be more than $#{BUDGET_LIMIT.to_fs(:delimited)}")
      end
    end

    def months_are_months
      if months.size > Conversation::MONTHS_LIMIT
        errors.add(:months, "can't be more than #{Conversation::MONTHS_LIMIT}")
      elsif !months.all? { |month| month.match?(MediaKit::MONTH) }
        errors.add(:months, "must be calendar months")
      end
    end
  end
end
