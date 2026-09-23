defmodule SymphonyElixir.Storage.IntakeCase do
  @moduledoc "A Jira issue accepted by an automation rule for analysis-only intake."

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Storage.AutomationRule
  alias SymphonyElixir.Storage.IntegrationConnection
  alias SymphonyElixir.Storage.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "intake_cases" do
    belongs_to(:project, Project)
    belongs_to(:rule, AutomationRule)
    belongs_to(:jira_connection, IntegrationConnection, foreign_key: :jira_connection_id)
    field(:jira_issue_id, :string)
    field(:jira_key, :string)
    field(:jira_url, :string)
    field(:title, :string)
    field(:description_text, :string)
    field(:priority_id, :string)
    field(:priority_name, :string)
    field(:jira_updated_at, :utc_datetime_usec)
    field(:detected_at, :utc_datetime_usec)
    field(:rule_snapshot, :map)
    field(:linear_issue_id, :binary_id)
    field(:linear_identifier, :string)
    field(:linear_url, :string)
    field(:linear_state_name, :string)
    field(:linear_confirmed_at, :utc_datetime_usec)
    field(:analysis_version, :integer, default: 1)
    field(:analysis_status, :string, default: "queued")
    field(:acknowledged_at, :utc_datetime_usec)
    field(:repair_approved_at, :utc_datetime_usec)
    field(:repair_approved_version, :integer)
    field(:lock_version, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(intake_case, attrs) do
    intake_case
    |> cast(attrs, [
      :project_id,
      :rule_id,
      :jira_connection_id,
      :jira_issue_id,
      :jira_key,
      :jira_url,
      :title,
      :description_text,
      :priority_id,
      :priority_name,
      :jira_updated_at,
      :detected_at,
      :rule_snapshot,
      :linear_issue_id,
      :linear_identifier,
      :linear_url,
      :linear_state_name,
      :linear_confirmed_at,
      :analysis_version,
      :analysis_status,
      :acknowledged_at,
      :repair_approved_at,
      :repair_approved_version,
      :lock_version
    ])
    |> ensure_description_text()
    |> put_uuid_default(:linear_issue_id)
    |> validate_required([
      :project_id,
      :rule_id,
      :jira_connection_id,
      :jira_issue_id,
      :jira_key,
      :jira_url,
      :title,
      :priority_id,
      :priority_name,
      :jira_updated_at,
      :detected_at,
      :rule_snapshot,
      :linear_issue_id,
      :analysis_version,
      :analysis_status,
      :lock_version
    ])
    |> validate_inclusion(:analysis_status, ~w(queued running ready needs_input failed))
    |> validate_number(:analysis_version, greater_than_or_equal_to: 1)
    |> validate_number(:repair_approved_version, greater_than_or_equal_to: 1)
    |> validate_number(:lock_version, greater_than_or_equal_to: 1)
    |> assoc_constraint(:project)
    |> assoc_constraint(:rule)
    |> assoc_constraint(:jira_connection)
    |> unique_constraint(:jira_issue_id, name: :intake_cases_jira_connection_id_jira_issue_id_index)
    |> unique_constraint(:linear_issue_id, name: :intake_cases_linear_issue_id_index)
  end

  defp put_uuid_default(changeset, field) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, Ecto.UUID.generate())
      _value -> changeset
    end
  end

  defp ensure_description_text(changeset) do
    if is_nil(get_field(changeset, :description_text)) do
      put_change(changeset, :description_text, "")
    else
      changeset
    end
  end
end
