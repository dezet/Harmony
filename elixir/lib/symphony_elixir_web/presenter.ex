defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard, Storage}
  alias SymphonyElixir.Storage.{WorkEvent, WorkRun}

  @durable_limit 50

  @doc """
  Builds the per-project summary payload from a pre-fetched snapshot and PR link list.

  Pure function: the caller (controller) is responsible for fetching snapshot and links.
  PR links are accepted as an argument rather than queried here, consistent with the
  module's convention that entry payload helpers are pure and Storage is only called
  from `durable_payload/0`.
  """
  @spec project_summary_payload(map(), map(), list()) :: map()
  def project_summary_payload(project, snapshot, pull_request_links) do
    running = filter_entries(snapshot.running, project)
    retrying = filter_entries(snapshot.retrying, project)
    blocked = filter_entries(Map.get(snapshot, :blocked, []), project)

    %{
      project: %{
        id: project.id,
        slug: project.slug,
        github_owner: project.github_owner,
        github_repo: project.github_repo,
        github_base_branch: project.github_base_branch,
        linear_project_slug: project.linear_project_slug,
        linear_team_key: project.linear_team_key,
        linear_human_review_state: project.linear_human_review_state,
        config_version: project.config_version
      },
      counts: %{
        running: length(running),
        retrying: length(retrying),
        blocked: length(blocked)
      },
      running: Enum.map(running, fn entry -> running_entry_payload(entry) |> Map.delete(:project) end),
      retrying: Enum.map(retrying, fn entry -> retry_entry_payload(entry) |> Map.delete(:project) end),
      blocked: Enum.map(blocked, fn entry -> blocked_entry_payload(entry) |> Map.delete(:project) end),
      human_review_prs: Enum.map(pull_request_links, &pr_link_payload/1)
    }
  end

  @doc """
  Builds the paginated work-run list payload.

  Expects `runs` to contain up to `page_size + 1` rows (overfetch pattern).
  When more than `page_size` rows are present, slices to `page_size` and computes
  `next_cursor` from the last visible row via `Storage.encode_work_run_cursor/1`.

  Timestamps are rendered as ISO 8601 UTC strings. The `payload` column is omitted.
  """
  @spec work_run_list_payload([WorkRun.t()], pos_integer()) :: map()
  def work_run_list_payload(runs, page_size) when is_integer(page_size) and page_size > 0 do
    {visible, has_more} =
      if length(runs) > page_size do
        {Enum.take(runs, page_size), true}
      else
        {runs, false}
      end

    next_cursor =
      if has_more do
        Storage.encode_work_run_cursor(List.last(visible))
      else
        nil
      end

    %{
      work_runs: Enum.map(visible, &work_run_list_item_payload/1),
      meta: %{
        next_cursor: next_cursor,
        page_size: page_size
      }
    }
  end

  @doc """
  Builds the run detail payload for a single run identified by `identifier`.

  Locates the live entry across the running/retrying/blocked snapshot lists by
  `issue_identifier == identifier`.  When a live entry is found its status wins
  ("running" | "retrying" | "blocked"); otherwise the durable `work_run.status`
  is used verbatim.

  Decision points:
  - `project`: optional 6th arg (struct or nil).  When nil and work_run has a
    project_id the response carries `%{id: project_id, slug: nil, name: nil}`.
    When a live entry has project fields they take precedence.
  - `tokens`: live token map when a live entry is present; `nil` for durable-only
    (WorkRun carries no token data).
  - `attempts`: sourced from the retry entry's `:attempt` field.  Running and
    blocked entries carry no attempt counter so both fields are `nil` for those
    states.  Durable-only → both `nil`.
  - `stream_cursor`: always `nil` here; the controller merges it in after
    fetching the first events page.
  """
  @spec run_detail_payload(
          String.t(),
          WorkRun.t() | nil,
          map(),
          list(),
          list(),
          map() | nil
        ) :: map()
  def run_detail_payload(identifier, work_run, snapshot, pr_links, artifacts, project \\ nil) do
    live = find_live_entry(identifier, snapshot)

    {live_running, live_retry, live_blocked} =
      case live do
        {:running, entry} -> {entry, nil, nil}
        {:retrying, entry} -> {nil, entry, nil}
        {:blocked, entry} -> {nil, nil, entry}
        nil -> {nil, nil, nil}
      end

    status =
      case live do
        {:running, _} -> "running"
        {:retrying, _} -> "retrying"
        {:blocked, _} -> "blocked"
        nil -> work_run && work_run.status
      end

    live_entry = live_running || live_retry || live_blocked

    issue_id =
      (live_entry && live_entry.issue_id) ||
        (work_run && work_run.linear_issue_id)

    work_run_id = work_run && work_run.id

    project_payload =
      cond do
        live_entry && not blank_project?(project_payload(live_entry)) ->
          project_payload(live_entry)

        not is_nil(project) ->
          project_payload_from_struct(project)

        work_run && work_run.project_id ->
          %{id: work_run.project_id, slug: nil, name: nil}

        true ->
          nil
      end

    workspace =
      if live_entry do
        %{
          path: Map.get(live_entry, :workspace_path),
          host: Map.get(live_entry, :worker_host)
        }
      else
        %{path: nil, host: nil}
      end

    {session_id, turn_count, started_at, last_event_at, last_event, last_message, tokens} =
      cond do
        live_running ->
          {
            live_running.session_id,
            Map.get(live_running, :turn_count, 0),
            iso8601(live_running.started_at),
            iso8601(live_running.last_codex_timestamp),
            live_running.last_codex_event,
            summarize_message(live_running.last_codex_message),
            %{
              input_tokens: live_running.codex_input_tokens,
              output_tokens: live_running.codex_output_tokens,
              total_tokens: live_running.codex_total_tokens
            }
          }

        live_blocked ->
          {
            live_blocked.session_id,
            nil,
            iso8601(Map.get(live_blocked, :started_at)),
            iso8601(live_blocked.last_codex_timestamp),
            live_blocked.last_codex_event,
            summarize_message(live_blocked.last_codex_message),
            nil
          }

        live_retry ->
          {
            nil,
            nil,
            iso8601(Map.get(live_retry, :started_at)),
            nil,
            nil,
            nil,
            nil
          }

        true ->
          {nil, nil, nil, nil, nil, nil, nil}
      end

    attempts =
      cond do
        live_retry ->
          attempt = live_retry.attempt || 0
          %{restart_count: max(attempt - 1, 0), current_retry_attempt: attempt}

        live_entry ->
          %{restart_count: nil, current_retry_attempt: nil}

        true ->
          %{restart_count: nil, current_retry_attempt: nil}
      end

    last_error =
      (live_blocked && live_blocked.error) ||
        (live_retry && live_retry.error)

    %{
      identifier: identifier,
      issue_id: issue_id,
      work_run_id: work_run_id,
      status: status,
      project: project_payload,
      workspace: workspace,
      session_id: session_id,
      turn_count: turn_count,
      started_at: started_at,
      last_event_at: last_event_at,
      last_event: last_event,
      last_message: last_message,
      tokens: tokens,
      attempts: attempts,
      pull_requests: Enum.map(pr_links, &pr_link_payload/1),
      artifacts: Enum.map(artifacts, &run_artifact_payload/1),
      last_error: last_error,
      stream_cursor: nil
    }
  end

  @doc """
  Builds the project artifacts list payload.

  Wraps the artifact list in `%{artifacts: [...]}`. Each item is projected via
  `project_artifact_payload/1` which omits `path` and inlines the preloaded
  `work_run` (or nil when the association is not set).
  """
  @spec project_artifacts_payload([map()]) :: map()
  def project_artifacts_payload(artifacts) do
    %{artifacts: Enum.map(artifacts, &project_artifact_payload/1)}
  end

  @doc """
  Builds a single project artifact item payload.

  Omits `path`. Inlines `work_run` as `%{linear_identifier, status, inserted_at}`
  when the association is loaded; nil when `work_run_id` is nil or the assoc is
  not loaded.
  """
  @spec project_artifact_payload(map()) :: map()
  def project_artifact_payload(artifact) do
    work_run_payload =
      case artifact.work_run do
        %SymphonyElixir.Storage.WorkRun{} = run ->
          %{
            linear_identifier: run.linear_identifier,
            status: run.status,
            inserted_at: iso8601(run.inserted_at)
          }

        _ ->
          nil
      end

    %{
      id: artifact.id,
      kind: artifact.kind,
      metadata: artifact.metadata,
      work_run_id: artifact.work_run_id,
      work_run: work_run_payload
    }
  end

  @doc """
  Builds the project activity page payload from a pre-fetched list of work events.

  `events` must be overfetched by +1 relative to `page_size`.  The function
  slices to `page_size` items and derives `next_cursor` from the last visible event
  via `Storage.encode_work_event_cursor/1`.

  Unlike `run_stream_payload`, this payload has no `has_live` field.
  """
  @spec project_activity_payload([WorkEvent.t()], pos_integer()) :: map()
  def project_activity_payload(events, page_size) when is_integer(page_size) and page_size > 0 do
    {visible, has_more} =
      if length(events) > page_size do
        {Enum.take(events, page_size), true}
      else
        {events, false}
      end

    next_cursor =
      if has_more do
        Storage.encode_work_event_cursor(List.last(visible))
      else
        nil
      end

    %{
      items: Enum.map(visible, &stream_event_payload/1),
      meta: %{next_cursor: next_cursor}
    }
  end

  @doc """
  Builds a stream page payload from a pre-fetched list of work events.

  `events` must be overfetched by +1 relative to `page_size`.  The function
  slices to `page_size` items (ascending) and derives `next_cursor` from the
  last visible event via `Storage.encode_work_event_cursor/1`.

  `has_live` is passed through from the caller (true when a live orchestrator
  entry exists for this run).
  """
  @spec run_stream_payload([WorkEvent.t()], pos_integer(), boolean()) :: map()
  def run_stream_payload(events, page_size, has_live)
      when is_integer(page_size) and page_size > 0 and is_boolean(has_live) do
    {visible, has_more} =
      if length(events) > page_size do
        {Enum.take(events, page_size), true}
      else
        {events, false}
      end

    next_cursor =
      if has_more do
        Storage.encode_work_event_cursor(List.last(visible))
      else
        nil
      end

    %{
      items: Enum.map(visible, &stream_event_payload/1),
      meta: %{
        next_cursor: next_cursor,
        has_live: has_live
      }
    }
  end

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, []))
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          runtime: runtime_payload(Map.get(snapshot, :runtime, %{})),
          artifacts: Enum.map(Map.get(snapshot, :artifacts, []), &artifact_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }
        |> maybe_put_projects(snapshot)
        |> maybe_put_durable()

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(running || blocked),
      last_error: (blocked && blocked.error) || (retry && retry.error),
      tracked: %{}
    }
    |> maybe_put_project(project_from_entries(running, retry, blocked))
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp project_from_entries(running, retry, blocked), do: project_payload(running || retry || blocked)

  defp project_payload(nil), do: nil

  defp project_payload(entry) do
    %{
      id: Map.get(entry, :project_id),
      name: Map.get(entry, :project_name),
      slug: Map.get(entry, :project_slug)
    }
  end

  defp projects_payload(snapshot) do
    entries = snapshot.running ++ snapshot.retrying ++ Map.get(snapshot, :blocked, [])

    entries
    |> Enum.map(&project_payload/1)
    |> Enum.reject(&blank_project?/1)
    |> Enum.uniq_by(&project_key/1)
    |> Enum.sort_by(&(&1.name || &1.slug || ""))
    |> Enum.map(fn project ->
      Map.put(project, :counts, %{
        running: Enum.count(snapshot.running, &(project_key(project_payload(&1)) == project_key(project))),
        retrying: Enum.count(snapshot.retrying, &(project_key(project_payload(&1)) == project_key(project))),
        blocked: Enum.count(Map.get(snapshot, :blocked, []), &(project_key(project_payload(&1)) == project_key(project)))
      })
    end)
  end

  defp maybe_put_projects(payload, snapshot) do
    case projects_payload(snapshot) do
      [] -> payload
      projects -> Map.put(payload, :projects, projects)
    end
  end

  defp maybe_put_project(payload, project) do
    if blank_project?(project), do: payload, else: Map.put(payload, :project, project)
  end

  defp maybe_put_durable(payload) do
    case durable_payload() do
      nil -> payload
      durable -> Map.put(payload, :durable, durable)
    end
  end

  defp durable_payload do
    durable = %{
      projects: Enum.map(Storage.list_projects(), &durable_project_payload/1),
      work_runs: Enum.map(Storage.list_recent_work_runs(@durable_limit), &durable_work_run_payload/1),
      pull_request_links: Enum.map(Storage.list_pull_request_links(@durable_limit), &durable_pull_request_link_payload/1),
      blockers: Enum.map(Storage.list_recent_blockers(@durable_limit), &durable_blocker_payload/1),
      dedupe_keys: Enum.map(Storage.list_recent_dedupe_keys(@durable_limit), &durable_dedupe_payload/1),
      work_events: Enum.map(Storage.list_recent_events(@durable_limit), &durable_event_payload/1),
      artifacts: Enum.map(Storage.list_recent_artifacts(@durable_limit), &durable_artifact_payload/1)
    }

    if Enum.all?(Map.values(durable), &(&1 == [])), do: nil, else: durable
  rescue
    DBConnection.OwnershipError -> nil
  end

  defp blank_project?(nil), do: true
  defp blank_project?(%{id: nil, name: nil, slug: nil}), do: true
  defp blank_project?(_project), do: false

  defp project_key(nil), do: nil
  defp project_key(%{slug: slug, id: id, name: name}), do: slug || id || name

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, _blocked), do: "blocked"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
    |> maybe_put_project(project_payload(entry))
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
    |> maybe_put_project(project_payload(entry))
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }
    |> maybe_put_project(project_payload(entry))
  end

  defp filter_entries(entries, project) do
    Enum.filter(entries, fn entry ->
      entry_project_id = Map.get(entry, :project_id)
      entry_project_slug = Map.get(entry, :project_slug)

      (is_binary(entry_project_id) and entry_project_id == project.id) or
        (is_binary(entry_project_slug) and entry_project_slug == project.slug)
    end)
  end

  defp pr_link_payload(link) do
    %{
      id: link.id,
      github_owner: link.github_owner,
      github_repo: link.github_repo,
      github_pr_number: link.github_pr_number,
      github_head_sha: link.github_head_sha,
      github_head_ref: link.github_head_ref,
      github_base_ref: link.github_base_ref,
      linear_identifier: link.linear_identifier,
      linear_url: link.linear_url,
      metadata: link.metadata
    }
  end

  defp find_live_entry(identifier, snapshot) do
    running = Enum.find(snapshot.running, &(&1.identifier == identifier))
    retry = Enum.find(snapshot.retrying, &(&1.identifier == identifier))
    blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == identifier))

    cond do
      running -> {:running, running}
      retry -> {:retrying, retry}
      blocked -> {:blocked, blocked}
      true -> nil
    end
  end

  defp project_payload_from_struct(project) do
    %{
      id: Map.get(project, :id),
      slug: Map.get(project, :slug),
      name: Map.get(project, :name) || Map.get(project, :linear_project_slug)
    }
  end

  defp run_artifact_payload(artifact) do
    %{
      id: artifact.id,
      kind: artifact.kind,
      path: artifact.path,
      metadata: artifact.metadata
    }
  end

  defp stream_event_payload(event) do
    %{
      id: event.id,
      kind: "work_event",
      type: event.type,
      at: iso8601(event.inserted_at),
      payload: event.payload
    }
  end

  defp work_run_list_item_payload(run) do
    %{
      id: run.id,
      project_id: run.project_id,
      type: run.type,
      status: run.status,
      dedupe_key: run.dedupe_key,
      github_owner: run.github_owner,
      github_repo: run.github_repo,
      github_pr_number: run.github_pr_number,
      github_head_sha: run.github_head_sha,
      github_head_ref: run.github_head_ref,
      github_base_ref: run.github_base_ref,
      linear_issue_id: run.linear_issue_id,
      linear_identifier: run.linear_identifier,
      linear_url: run.linear_url,
      agent_backend: run.agent_backend,
      inserted_at: iso8601(run.inserted_at),
      updated_at: iso8601(run.updated_at)
    }
  end

  defp artifact_payload(artifact) do
    %{
      kind: Map.get(artifact, :kind) || Map.get(artifact, "kind"),
      path: Map.get(artifact, :path) || Map.get(artifact, "path")
    }
  end

  defp durable_project_payload(project) do
    %{
      id: project.id,
      slug: project.slug,
      linear: %{
        project_slug: project.linear_project_slug,
        team_key: project.linear_team_key,
        human_review_state: project.linear_human_review_state
      },
      github: %{
        owner: project.github_owner,
        repo: project.github_repo,
        base_branch: project.github_base_branch
      },
      config_version: project.config_version
    }
  end

  defp durable_work_run_payload(run) do
    %{
      id: run.id,
      project_id: run.project_id,
      type: run.type,
      status: run.status,
      dedupe_key: run.dedupe_key,
      github_owner: run.github_owner,
      github_repo: run.github_repo,
      github_pr_number: run.github_pr_number,
      github_head_sha: run.github_head_sha,
      github_head_ref: run.github_head_ref,
      github_base_ref: run.github_base_ref,
      linear_issue_id: run.linear_issue_id,
      linear_identifier: run.linear_identifier,
      linear_url: run.linear_url,
      agent_backend: run.agent_backend,
      payload: run.payload
    }
  end

  defp durable_pull_request_link_payload(link) do
    %{
      id: link.id,
      project_id: link.project_id,
      github_owner: link.github_owner,
      github_repo: link.github_repo,
      github_pr_number: link.github_pr_number,
      github_head_sha: link.github_head_sha,
      github_head_ref: link.github_head_ref,
      github_base_ref: link.github_base_ref,
      linear_issue_id: link.linear_issue_id,
      linear_identifier: link.linear_identifier,
      linear_url: link.linear_url,
      metadata: link.metadata
    }
  end

  defp durable_blocker_payload(blocker) do
    %{
      id: blocker.id,
      project_id: blocker.project_id,
      work_run_id: blocker.work_run_id,
      target_type: blocker.target_type,
      target_id: blocker.target_id,
      reason: blocker.reason,
      status: blocker.status,
      metadata: blocker.metadata
    }
  end

  defp durable_dedupe_payload(dedupe) do
    %{
      id: dedupe.id,
      project_id: dedupe.project_id,
      key: dedupe.key,
      scope: dedupe.scope,
      status: dedupe.status,
      metadata: dedupe.metadata
    }
  end

  defp durable_event_payload(event) do
    %{
      id: event.id,
      project_id: event.project_id,
      work_run_id: event.work_run_id,
      type: event.type,
      payload: event.payload,
      inserted_at: iso8601(event.inserted_at)
    }
  end

  defp durable_artifact_payload(artifact) do
    %{
      id: artifact.id,
      project_id: artifact.project_id,
      work_run_id: artifact.work_run_id,
      kind: artifact.kind,
      path: artifact.path,
      metadata: artifact.metadata
    }
  end

  defp runtime_payload(runtime) when is_map(runtime) do
    %{sandbox: sandbox_payload(Map.get(runtime, :sandbox) || Map.get(runtime, "sandbox") || %{})}
  end

  defp runtime_payload(_runtime), do: %{sandbox: sandbox_payload(%{})}

  defp sandbox_payload(sandbox) when is_map(sandbox) do
    %{
      bubblewrap_available: Map.get(sandbox, :bubblewrap_available) || Map.get(sandbox, "bubblewrap_available") || false,
      apparmor_restrict_unprivileged_userns:
        Map.get(sandbox, :apparmor_restrict_unprivileged_userns) ||
          Map.get(sandbox, "apparmor_restrict_unprivileged_userns"),
      thread_sandbox: Map.get(sandbox, :thread_sandbox) || Map.get(sandbox, "thread_sandbox"),
      turn_sandbox_type: Map.get(sandbox, :turn_sandbox_type) || Map.get(sandbox, "turn_sandbox_type"),
      posture: Map.get(sandbox, :posture) || Map.get(sandbox, "posture"),
      warnings: Map.get(sandbox, :warnings) || Map.get(sandbox, "warnings") || []
    }
  end

  defp sandbox_payload(_sandbox), do: sandbox_payload(%{})

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }
  end

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: entry.last_codex_event,
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
