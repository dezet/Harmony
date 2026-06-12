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

  @spec list_recent_work_runs(pos_integer()) :: [WorkRun.t()]
  def list_recent_work_runs(limit) when is_integer(limit) and limit > 0 do
    WorkRun
    |> order_by([run], desc: run.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec list_work_runs_for_project(binary(), map()) :: [WorkRun.t()]
  def list_work_runs_for_project(project_id, opts \\ %{}) when is_binary(project_id) do
    page_size = Map.get(opts, :page_size, 25)

    WorkRun
    |> where([run], run.project_id == ^project_id)
    |> filter_work_run_status(Map.get(opts, :status))
    |> apply_work_run_cursor(Map.get(opts, :cursor))
    |> order_by([run], desc: run.inserted_at, desc: run.id)
    |> limit(^(page_size + 1))
    |> Repo.all()
  end

  @spec encode_work_run_cursor(WorkRun.t()) :: binary()
  def encode_work_run_cursor(%WorkRun{} = run) do
    json = Jason.encode!(%{"inserted_at" => DateTime.to_iso8601(run.inserted_at), "id" => run.id})
    Base.url_encode64(json, padding: false)
  end

  @spec decode_work_run_cursor(binary()) :: {:ok, %{inserted_at: DateTime.t(), id: binary()}} | :error
  def decode_work_run_cursor(binary) when is_binary(binary) do
    with {:ok, json} <- Base.url_decode64(binary, padding: false),
         {:ok, %{"inserted_at" => ts_str, "id" => id}} when is_binary(ts_str) and is_binary(id) <- Jason.decode(json),
         {:ok, inserted_at, _offset} <- DateTime.from_iso8601(ts_str) do
      {:ok, %{inserted_at: inserted_at, id: id}}
    else
      _ -> :error
    end
  end

  @spec list_pull_request_links(pos_integer()) :: [PullRequestLink.t()]
  def list_pull_request_links(limit) when is_integer(limit) and limit > 0 do
    PullRequestLink
    |> order_by([link], desc: link.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec list_pull_request_links_for_project(binary()) :: [PullRequestLink.t()]
  def list_pull_request_links_for_project(project_id) when is_binary(project_id) do
    PullRequestLink
    |> where([link], link.project_id == ^project_id)
    |> order_by([link], desc: link.updated_at)
    |> Repo.all()
  end

  @spec list_recent_blockers(pos_integer()) :: [Blocker.t()]
  def list_recent_blockers(limit) when is_integer(limit) and limit > 0 do
    Blocker
    |> order_by([blocker], desc: blocker.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec list_recent_dedupe_keys(pos_integer()) :: [DedupeKey.t()]
  def list_recent_dedupe_keys(limit) when is_integer(limit) and limit > 0 do
    DedupeKey
    |> order_by([dedupe], desc: dedupe.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec list_recent_events(pos_integer()) :: [WorkEvent.t()]
  def list_recent_events(limit) when is_integer(limit) and limit > 0 do
    WorkEvent
    |> order_by([event], desc: event.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec list_recent_artifacts(pos_integer()) :: [Artifact.t()]
  def list_recent_artifacts(limit) when is_integer(limit) and limit > 0 do
    Artifact
    |> order_by([artifact], desc: artifact.inserted_at)
    |> limit(^limit)
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

  @spec work_event_exists?(binary(), binary(), String.t()) :: boolean()
  def work_event_exists?(project_id, work_run_id, type)
      when is_binary(project_id) and is_binary(work_run_id) and is_binary(type) do
    Repo.exists?(
      from(event in WorkEvent,
        where: event.project_id == ^project_id and event.work_run_id == ^work_run_id and event.type == ^type
      )
    )
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

  @spec dedupe_status(binary(), String.t()) :: String.t() | nil
  def dedupe_status(project_id, key) when is_binary(project_id) and is_binary(key) do
    DedupeKey
    |> where([d], d.project_id == ^project_id and d.key == ^key)
    |> select([d], d.status)
    |> Repo.one()
  end

  @spec mark_dedupe_claimed(map()) :: {:ok, DedupeKey.t()} | {:error, Ecto.Changeset.t()}
  def mark_dedupe_claimed(attrs) when is_map(attrs), do: upsert_dedupe_status(attrs, "claimed")

  @spec mark_dedupe_processed(map()) :: {:ok, DedupeKey.t()} | {:error, Ecto.Changeset.t()}
  def mark_dedupe_processed(attrs) when is_map(attrs) do
    upsert_dedupe_status(attrs, "processed")
  end

  @spec mark_dedupe_blocked(map()) :: {:ok, DedupeKey.t()} | {:error, Ecto.Changeset.t()}
  def mark_dedupe_blocked(attrs) when is_map(attrs), do: upsert_dedupe_status(attrs, "blocked")

  @spec open_blocker_exists?(binary(), String.t(), String.t()) :: boolean()
  def open_blocker_exists?(project_id, target_type, target_id)
      when is_binary(project_id) and is_binary(target_type) and is_binary(target_id) do
    Repo.exists?(
      from(b in Blocker,
        where:
          b.project_id == ^project_id and b.target_type == ^target_type and b.target_id == ^target_id and
            b.status == "open"
      )
    )
  end

  @spec find_pull_request_link_for_linear(binary(), String.t() | nil, String.t() | nil) ::
          PullRequestLink.t() | nil
  def find_pull_request_link_for_linear(project_id, linear_issue_id, linear_identifier) when is_binary(project_id) do
    PullRequestLink
    |> where([link], link.project_id == ^project_id)
    |> where_linear_match(linear_issue_id, linear_identifier)
    |> order_by([link], desc: link.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  defp upsert_dedupe_status(attrs, status) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("status", status)
      |> Map.put_new("metadata", %{})

    %DedupeKey{}
    |> DedupeKey.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:scope, :status, :metadata, :updated_at]},
      conflict_target: [:project_id, :key],
      returning: true
    )
  end

  defp where_linear_match(query, linear_issue_id, linear_identifier) do
    cond do
      is_binary(linear_issue_id) and linear_issue_id != "" ->
        where(query, [link], link.linear_issue_id == ^linear_issue_id or link.linear_identifier == ^linear_identifier)

      is_binary(linear_identifier) and linear_identifier != "" ->
        where(query, [link], link.linear_identifier == ^linear_identifier)

      true ->
        where(query, [_link], false)
    end
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
           :github_head_ref,
           :github_base_ref,
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

  defp filter_work_run_status(query, nil), do: query

  defp filter_work_run_status(query, status) when is_binary(status) do
    where(query, [run], run.status == ^status)
  end

  defp apply_work_run_cursor(query, nil), do: query

  defp apply_work_run_cursor(query, cursor) when is_binary(cursor) do
    case decode_work_run_cursor(cursor) do
      {:ok, %{inserted_at: ts, id: id}} ->
        where(query, [run], run.inserted_at < ^ts or (run.inserted_at == ^ts and run.id < ^id))

      :error ->
        query
    end
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end
end
