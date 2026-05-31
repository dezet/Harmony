defmodule SymphonyElixir.Storage do
  @moduledoc """
  Durable storage context for Harmony work orchestration.
  """

  import Ecto.Query

  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{Artifact, Blocker, DedupeKey, Project, PullRequestLink, WorkEvent, WorkRun}

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

  @spec list_projects() :: [Project.t()]
  def list_projects do
    Project
    |> order_by([project], asc: project.slug)
    |> Repo.all()
  end

  @spec create_work_run(map()) :: {:ok, WorkRun.t()} | {:error, Ecto.Changeset.t()}
  def create_work_run(attrs) when is_map(attrs) do
    %WorkRun{}
    |> WorkRun.changeset(stringify_keys(attrs))
    |> Repo.insert()
  end

  @spec upsert_work_run(map()) :: {:ok, WorkRun.t()} | {:error, Ecto.Changeset.t()}
  def upsert_work_run(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    %WorkRun{}
    |> WorkRun.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :type,
           :status,
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
           :payload,
           :updated_at
         ]},
      conflict_target: {:unsafe_fragment, "(project_id, dedupe_key) WHERE dedupe_key IS NOT NULL"},
      returning: true
    )
  end

  @spec append_event(map()) :: {:ok, WorkEvent.t()} | {:error, Ecto.Changeset.t()}
  def append_event(attrs) when is_map(attrs) do
    %WorkEvent{}
    |> WorkEvent.changeset(stringify_keys(attrs))
    |> Repo.insert()
  end

  @spec create_artifact(map()) :: {:ok, Artifact.t()} | {:error, Ecto.Changeset.t()}
  def create_artifact(attrs) when is_map(attrs) do
    %Artifact{}
    |> Artifact.changeset(stringify_keys(attrs))
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

  @spec dedupe_seen?(binary(), String.t()) :: boolean()
  def dedupe_seen?(project_id, key) when is_binary(project_id) and is_binary(key) do
    Repo.exists?(from(d in DedupeKey, where: d.project_id == ^project_id and d.key == ^key))
  end

  @spec mark_dedupe_processed(map()) :: {:ok, DedupeKey.t()} | {:error, Ecto.Changeset.t()}
  def mark_dedupe_processed(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new("status", "processed")
      |> Map.put_new("metadata", %{})

    %DedupeKey{}
    |> DedupeKey.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:project_id, :key],
      returning: true
    )
  end

  @spec upsert_pull_request_link(map()) :: {:ok, PullRequestLink.t()} | {:error, Ecto.Changeset.t()}
  def upsert_pull_request_link(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    %PullRequestLink{}
    |> PullRequestLink.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :github_head_sha,
           :linear_issue_id,
           :linear_identifier,
           :linear_url,
           :metadata,
           :updated_at
         ]},
      conflict_target: [:project_id, :github_owner, :github_repo, :github_pr_number],
      returning: true
    )
  end

  @spec get_project_by_slug(String.t()) :: Project.t() | nil
  def get_project_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Project, slug: slug)
  end

  @spec get_project_by_github(String.t(), String.t()) :: Project.t() | nil
  def get_project_by_github(owner, repo) when is_binary(owner) and is_binary(repo) do
    Repo.get_by(Project, github_owner: owner, github_repo: repo)
  end

  @spec get_project!(Ecto.UUID.t()) :: Project.t()
  def get_project!(id) when is_binary(id) do
    Repo.get!(Project, id)
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
