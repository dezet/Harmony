defmodule SymphonyElixir.Storage.WorkRun do
  @moduledoc """
  Durable unit of Harmony work claimed from Linear or GitHub.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Storage.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "work_runs" do
    belongs_to(:project, Project)
    field(:type, :string)
    field(:status, :string)
    field(:dedupe_key, :string)
    field(:github_owner, :string)
    field(:github_repo, :string)
    field(:github_pr_number, :integer)
    field(:github_head_sha, :string)
    field(:github_head_ref, :string)
    field(:github_base_ref, :string)
    field(:linear_issue_id, :string)
    field(:linear_identifier, :string)
    field(:linear_url, :string)
    field(:agent_backend, :string, default: "codex")
    field(:payload, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(work_run, attrs) do
    work_run
    |> cast(attrs, [
      :project_id,
      :type,
      :status,
      :dedupe_key,
      :github_owner,
      :github_repo,
      :github_pr_number,
      :github_head_sha,
      :github_head_ref,
      :github_base_ref,
      :linear_issue_id,
      :linear_identifier,
      :linear_url,
      :agent_backend,
      :payload
    ])
    |> validate_required([:project_id, :type, :status, :agent_backend, :payload])
    |> assoc_constraint(:project)
    |> unique_constraint(:dedupe_key, name: :work_runs_project_id_dedupe_key_index)
  end
end
