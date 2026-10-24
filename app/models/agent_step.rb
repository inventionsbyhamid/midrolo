class AgentStep < ApplicationRecord
  STATUSES = %w[running ok warning error].freeze

  belongs_to :report

  enum :status, STATUSES.index_with(&:itself), validate: true

  after_create_commit -> { broadcast_append_to report, target: "agent_steps", partial: "reports/step", locals: { agent_step: self } }
  after_update_commit -> { broadcast_replace_to report, target: dom_id_for_step, partial: "reports/step", locals: { agent_step: self } }

  private

  def dom_id_for_step = ActionView::RecordIdentifier.dom_id(self)
end
