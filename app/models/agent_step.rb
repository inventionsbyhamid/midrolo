class AgentStep < ApplicationRecord
  STATUSES = %w[running ok warning error].freeze

  belongs_to :report

  enum :status, STATUSES.index_with(&:itself), validate: true

  # Only the owner's report page streams (a public sample never does), so the steps go out as written.
  after_create_commit -> { broadcast_append_to report, target: ActionView::RecordIdentifier.dom_id(report, :agent_steps), partial: "reports/step", locals: { agent_step: self, read_only: false } }
  after_update_commit -> { broadcast_replace_to report, target: dom_id_for_step, partial: "reports/step", locals: { agent_step: self, read_only: false } }

  private

  def dom_id_for_step = ActionView::RecordIdentifier.dom_id(self)
end
