defmodule Mix.Tasks.Harmony.ReactSpaE2eServer do
  use Mix.Task

  alias __MODULE__.SnapshotOrchestrator
  alias SymphonyElixir.{HttpServer, Storage}

  @moduledoc """
  Serves the React SPA against a deterministic browser E2E snapshot source.
  """
  @shortdoc "Serves a deterministic React SPA browser E2E harness"

  @default_port 4201
  @switches [port: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      invalid != [] ->
        Mix.raise("Invalid options: #{inspect(invalid)}")

      argv != [] ->
        Mix.raise("Unexpected arguments: #{Enum.join(argv, " ")}")

      true ->
        :ok
    end

    port = Keyword.get(opts, :port, @default_port)

    unless is_integer(port) and port >= 0 do
      Mix.raise("--port must be a non-negative integer")
    end

    install_runtime_guards()
    Mix.Task.run("app.start")

    seed_e2e_project()

    orchestrator = unique_orchestrator_name()
    {:ok, _pid} = SnapshotOrchestrator.start_link(name: orchestrator)

    serve_forever(port, orchestrator)
  end

  defp serve_forever(port, orchestrator) do
    case HttpServer.start_link(
           port: port,
           host: "127.0.0.1",
           orchestrator: orchestrator,
           snapshot_timeout_ms: 100
         ) do
      {:ok, _pid} ->
        Mix.shell().info("react_spa_e2e_server=http://127.0.0.1:#{port}")
        Process.sleep(:infinity)

      {:error, {:already_started, _pid}} ->
        Mix.shell().info("react_spa_e2e_server=http://127.0.0.1:#{port}")
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.raise("failed to start React SPA E2E HTTP server: #{inspect(reason)}")

      :ignore ->
        Mix.raise("failed to start React SPA E2E HTTP server: ignored")
    end
  end

  # Upserts the deterministic e2e project so that /api/v1/projects/:ref/summary
  # and /api/v1/work_runs?project=react-spa-e2e respond with real data in the
  # e2e harness (both controllers read from Postgres; the snapshot orchestrator
  # provides the live-entry portion of the summary).
  defp seed_e2e_project do
    {:ok, project} =
      Storage.upsert_project(%{
        slug: "react-spa-e2e",
        github_owner: "harmony-e2e",
        github_repo: "react-spa-e2e",
        github_base_branch: "main",
        linear_project_slug: "react-spa-e2e",
        linear_team_key: "COD",
        linear_human_review_state: "Human Review",
        config_version: 1,
        config: %{}
      })

    seed_e2e_run(project)
    :ok
  end

  # Upserts a durable WorkRun for COD-1 (the identifier that the snapshot
  # version=1 puts in the running list) so that /api/v1/runs/COD-1 and
  # /api/v1/runs/COD-1/stream return real data in the e2e harness.
  defp seed_e2e_run(project) do
    {:ok, work_run} =
      Storage.upsert_work_run(%{
        project_id: project.id,
        type: "linear_issue",
        status: "running",
        dedupe_key: "e2e-cod-1",
        linear_issue_id: "react-spa-e2e-1",
        linear_identifier: "COD-1",
        agent_backend: "codex",
        payload: %{}
      })

    unless Storage.work_event_exists?(project.id, work_run.id, "run_started") do
      {:ok, _event} =
        Storage.append_event(%{
          project_id: project.id,
          work_run_id: work_run.id,
          type: "run_started",
          payload: %{message: "E2E run started"}
        })
    end

    :ok
  end

  defp unique_orchestrator_name do
    :"#{__MODULE__}.SnapshotOrchestrator.#{System.unique_integer([:positive])}"
  end

  defp install_runtime_guards do
    Application.put_env(:symphony_elixir, :work_source_fetchers, [])
  end

  defmodule SnapshotOrchestrator do
    @moduledoc false

    use GenServer

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      GenServer.start_link(__MODULE__, 1, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(version), do: {:ok, version}

    @impl true
    def handle_call(:snapshot, _from, version) do
      {:reply, snapshot(version), version}
    end

    def handle_call(:request_refresh, _from, version) do
      next_version = version + 1
      Process.send_after(self(), :broadcast_update, 0)

      {:reply,
       %{
         queued: true,
         coalesced: false,
         requested_at: DateTime.utc_now(),
         operations: ["poll", "reconcile"]
       }, next_version}
    end

    @impl true
    def handle_info(:broadcast_update, version) do
      :ok = SymphonyElixirWeb.ObservabilityPubSub.broadcast_update()
      {:noreply, version}
    end

    defp snapshot(version) do
      %{
        running: [running_entry(version)],
        retrying: [],
        blocked: [],
        runtime: runtime(),
        artifacts: [
          %{
            kind: "screenshot",
            path: ".harmony/artifacts/react-e2e-#{version}.png"
          }
        ],
        codex_totals: %{
          input_tokens: 100 + version,
          output_tokens: 50 + version,
          total_tokens: 150 + version,
          seconds_running: version
        },
        rate_limits: %{}
      }
    end

    defp running_entry(version) do
      now = DateTime.utc_now()

      %{
        issue_id: "react-spa-e2e-#{version}",
        identifier: "COD-#{version}",
        project_id: "react-spa-e2e",
        project_name: "React SPA E2E",
        project_slug: "react-spa-e2e",
        state: "In Progress",
        worker_host: "127.0.0.1",
        workspace_path: "/tmp/harmony-react-spa-e2e-#{version}",
        session_id: "react-spa-e2e-session-#{version}",
        turn_count: version,
        last_codex_event: "snapshot",
        last_codex_message: "React SPA E2E snapshot #{version}",
        started_at: DateTime.add(now, -version, :second),
        last_codex_timestamp: now,
        codex_input_tokens: 100 + version,
        codex_output_tokens: 50 + version,
        codex_total_tokens: 150 + version
      }
    end

    defp runtime do
      %{
        sandbox: %{
          bubblewrap_available: false,
          apparmor_restrict_unprivileged_userns: nil,
          thread_sandbox: "workspace-write",
          turn_sandbox_type: "workspaceWrite",
          posture: "deterministic",
          warnings: []
        }
      }
    end
  end
end
