defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard, Storage}

  @durable_limit 50

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
