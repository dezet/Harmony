defmodule SymphonyElixir.Storage.JiraObservation do
  @moduledoc "The latest durable observation of a Jira issue for a rule."

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Storage.AutomationRule
  alias SymphonyElixir.Storage.IntegrationConnection

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "jira_observations" do
    belongs_to(:jira_connection, IntegrationConnection, foreign_key: :jira_connection_id)
    belongs_to(:rule, AutomationRule)
    field(:jira_issue_id, :string)
    field(:first_seen_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:last_priority_id, :string)
    field(:baseline_excluded, :boolean, default: false)
    field(:generation, :binary_id)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(observation, attrs) do
    observation
    |> cast(attrs, [
      :jira_connection_id,
      :rule_id,
      :jira_issue_id,
      :first_seen_at,
      :last_seen_at,
      :last_priority_id,
      :baseline_excluded,
      :generation
    ])
    |> validate_required([
      :jira_connection_id,
      :rule_id,
      :jira_issue_id,
      :first_seen_at,
      :last_seen_at,
      :baseline_excluded
    ])
    |> validate_length(:jira_issue_id, min: 1)
    |> assoc_constraint(:jira_connection)
    |> assoc_constraint(:rule)
    |> unique_constraint(:jira_issue_id, name: :jira_observations_rule_id_jira_issue_id_index)
  end
end
