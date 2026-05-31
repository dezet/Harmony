defmodule SymphonyElixir.Storage do
  @moduledoc """
  Durable storage context for Harmony work orchestration.
  """

  import Ecto.Query

  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{Blocker, Project, WorkEvent, WorkRun}

  @spec upsert_project(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def upsert_project(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :linear_project_slug,
           :linear_team_key,
           :linear_human_review_state,
           :github_owner,
           :github_repo,
           :github_base_branch,
           :config_version,
           :config,
           :updated_at
         ]},
      conflict_target: [:slug],
      returning: true
    )
  end

  @spec create_work_run(map()) :: {:ok, WorkRun.t()} | {:error, Ecto.Changeset.t()}
  def create_work_run(attrs) when is_map(attrs) do
    %WorkRun{}
    |> WorkRun.changeset(stringify_keys(attrs))
    |> Repo.insert()
  end

  @spec append_event(map()) :: {:ok, WorkEvent.t()} | {:error, Ecto.Changeset.t()}
  def append_event(attrs) when is_map(attrs) do
    %WorkEvent{}
    |> WorkEvent.changeset(stringify_keys(attrs))
    |> Repo.insert()
  end

  @spec upsert_open_blocker(map()) :: {:ok, Blocker.t()} | {:error, Ecto.Changeset.t()}
  def upsert_open_blocker(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("status", "open")

    %Blocker{}
    |> Blocker.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:reason, :metadata, :updated_at]},
      conflict_target: {:unsafe_fragment, "(project_id, target_type, target_id, status) WHERE status = 'open'"},
      returning: true
    )
  end

  @spec get_project_by_slug(String.t()) :: Project.t() | nil
  def get_project_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Project, slug: slug)
  end

  @spec list_queued_runs() :: [WorkRun.t()]
  def list_queued_runs do
    WorkRun
    |> where([run], run.status == "queued")
    |> order_by([run], asc: run.inserted_at)
    |> Repo.all()
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end
end
