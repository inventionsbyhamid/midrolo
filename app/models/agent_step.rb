class AgentStep < ApplicationRecord
  STATUSES = %w[running ok warning error].freeze
  # What a step can belong to: a podcaster's report, or a brand's fit search (Research::StepLogger logs both).
  RUN_TYPES = %w[Report FitSearch].freeze

  belongs_to :run, polymorphic: true

  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :run_type, inclusion: { in: RUN_TYPES }

  # Only the owner's page streams (a public sample never does), so the steps go out as written.
  after_create_commit -> { broadcast_append_to run, target: ActionView::RecordIdentifier.dom_id(run, :agent_steps), partial: "reports/step", locals: { agent_step: self, read_only: false } }
  after_update_commit -> { broadcast_replace_to run, target: dom_id_for_step, partial: "reports/step", locals: { agent_step: self, read_only: false } }

  private

  def dom_id_for_step = ActionView::RecordIdentifier.dom_id(self)
end
