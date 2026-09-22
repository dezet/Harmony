defmodule SymphonyElixir.Storage.AutomationRule do
  @moduledoc "Jira intake rule configuration and its durable polling state."

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Storage.IntegrationConnection
  alias SymphonyElixir.Storage.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "automation_rules" do
    belongs_to(:project, Project)
    belongs_to(:jira_connection, IntegrationConnection, foreign_key: :jira_connection_id)
    belongs_to(:email_connection, IntegrationConnection, foreign_key: :email_connection_id)
    belongs_to(:sms_connection, IntegrationConnection, foreign_key: :sms_connection_id)

    field(:name, :string)
    field(:source_type, :string)
    field(:source_id, :string)
    field(:priority_ids, {:array, :string}, default: [])
    field(:interval_seconds, :integer, default: 300)
    field(:initial_policy, :string, default: "new_matches_only")
    field(:linear_team_id, :string)
    field(:linear_project_id, :string)
    field(:linear_todo_state_id, :string)
    field(:linear_hold_label_id, :string)
    field(:email_recipients, {:array, :string}, default: [])
    field(:sms_recipients, {:array, :string}, default: [])
    field(:enabled, :boolean, default: false)
    field(:config_version, :integer, default: 1)
    field(:activation_status, :string, default: "idle")
    field(:activated_at, :utc_datetime_usec)
    field(:baseline_complete_at, :utc_datetime_usec)
    field(:last_started_at, :utc_datetime_usec)
    field(:last_success_at, :utc_datetime_usec)
    field(:next_poll_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    field(:lease_token, :string)
    field(:lease_until, :utc_datetime_usec)
    field(:baseline_generation, :binary_id)
    field(:lock_version, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :project_id,
      :jira_connection_id,
      :name,
      :source_type,
      :source_id,
      :priority_ids,
      :interval_seconds,
      :initial_policy,
      :linear_team_id,
      :linear_project_id,
      :linear_todo_state_id,
      :linear_hold_label_id,
      :email_connection_id,
      :sms_connection_id,
      :email_recipients,
      :sms_recipients,
      :enabled,
      :config_version,
      :activation_status,
      :activated_at,
      :baseline_complete_at,
      :last_started_at,
      :last_success_at,
      :next_poll_at,
      :last_error_code,
      :lease_token,
      :lease_until,
      :baseline_generation,
      :lock_version
    ])
    |> validate_required([
      :project_id,
      :jira_connection_id,
      :name,
      :source_type,
      :source_id,
      :priority_ids,
      :interval_seconds,
      :initial_policy,
      :linear_team_id,
      :linear_project_id,
      :linear_todo_state_id,
      :linear_hold_label_id,
      :email_recipients,
      :sms_recipients,
      :enabled,
      :config_version,
      :activation_status,
      :lock_version
    ])
    |> validate_inclusion(:source_type, ~w(board filter))
    |> validate_inclusion(:initial_policy, ~w(new_matches_only include_existing))
    |> validate_inclusion(:activation_status, ~w(idle activating error))
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:source_id, min: 1)
    |> validate_number(:interval_seconds, greater_than_or_equal_to: 60, less_than_or_equal_to: 86_400)
    |> validate_number(:config_version, greater_than_or_equal_to: 1)
    |> validate_number(:lock_version, greater_than_or_equal_to: 1)
    |> validate_change(:priority_ids, fn :priority_ids, values ->
      if is_list(values) and values != [] and Enum.all?(values, &(is_binary(&1) and &1 != "")) do
        []
      else
        [priority_ids: "must contain at least one non-empty ID"]
      end
    end)
    |> assoc_constraint(:project)
    |> assoc_constraint(:jira_connection)
    |> assoc_constraint(:email_connection)
    |> assoc_constraint(:sms_connection)
    |> unique_constraint(:source_id, name: :automation_rules_active_source_index)
  end
end
