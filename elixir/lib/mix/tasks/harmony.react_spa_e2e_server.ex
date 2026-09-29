defmodule Mix.Tasks.Harmony.ReactSpaE2eServer do
  use Mix.Task

  alias __MODULE__.{IntakeSeed, ProviderStubs, SnapshotOrchestrator}
  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.{Config, HttpServer, Repo, Storage}
  alias SymphonyElixir.Storage.{Project, WorkRun}

  @moduledoc """
  Serves the React SPA against a deterministic browser E2E snapshot source.

  The harness uses its own PostgreSQL database (`harmony_e2e`, or
  `HARMONY_E2E_DATABASE_NAME`), created and migrated on start. After boot the
  repo runs in a shared SQL sandbox: the seeded data and every write made by
  the suite live in one transaction that is never committed, so each run
  starts from the same data and the database keeps nothing afterwards.

  Intake runs with a synthetic workflow (`intake.enabled: false`,
  `intake.effects_enabled: true`): no scheduler or dispatcher starts, and the
  Jira, Linear, SMTP and SMSAPI calls of the controllers go to in-process
  stubs (`ProviderStubs`). Nothing leaves the machine.
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
    prepare_database!()
    Mix.Task.run("app.start")
    checkout_shared_sandbox!()

    portal = seed_e2e_project()
    :ok = IntakeSeed.seed!(portal)

    orchestrator = unique_orchestrator_name()
    {:ok, _pid} = SnapshotOrchestrator.start_link(name: orchestrator)

    scheduler = :"#{__MODULE__}.SchedulerStub"
    {:ok, _pid} = ProviderStubs.start_link(name: scheduler)
    install_intake_adapters(scheduler)

    serve_forever(port, orchestrator)
  end

  @e2e_database "harmony_e2e"

  # A dedicated database, created and migrated before the sandbox pool is
  # installed; the development database is never touched.
  defp prepare_database! do
    database = System.get_env("HARMONY_E2E_DATABASE_NAME", @e2e_database)

    unless database =~ "e2e" do
      Mix.raise("HARMONY_E2E_DATABASE_NAME must name a dedicated E2E database (contain \"e2e\"), got: #{database}")
    end

    repo_config = Application.get_env(:symphony_elixir, Repo, [])
    Application.put_env(:symphony_elixir, Repo, Keyword.merge(repo_config, database: database))

    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])

    Application.put_env(
      :symphony_elixir,
      Repo,
      Keyword.merge(repo_config, database: database, pool: Sandbox, ownership_timeout: :infinity)
    )
  end

  defp checkout_shared_sandbox! do
    :ok = Sandbox.checkout(Repo, ownership_timeout: :infinity)
    :ok = Sandbox.mode(Repo, {:shared, self()})

    if Repo.aggregate(Project, :count) != 0 do
      Mix.raise("The E2E database is not empty; the harness only writes inside its sandbox and expects no committed rows")
    end
  end

  defp install_intake_adapters(scheduler) do
    endpoint = SymphonyElixirWeb.Endpoint
    config = Application.get_env(:symphony_elixir, endpoint, [])
    Application.put_env(:symphony_elixir, endpoint, Keyword.put(config, :intake_adapters, ProviderStubs.adapters(scheduler)))
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
        display_name: "Portal klienta",
        ui_color: "purple",
        forge_owner: "harmony-e2e",
        forge_repo: "react-spa-e2e",
        forge_base_branch: "main",
        linear_project_slug: "react-spa-e2e",
        linear_team_key: "COD",
        linear_human_review_state: "Human Review",
        config_version: 1,
        config: %{}
      })

    seed_e2e_run(project)
    project
  end

  # Inserts a durable WorkRun for COD-1 (the identifier that the snapshot
  # version=1 puts in the running list) so that /api/v1/runs/COD-1 and
  # /api/v1/runs/COD-1/stream return real data in the e2e harness.
  # Its `inserted_at` is fixed so the case projection orders it
  # deterministically next to the seeded intake cases.
  defp seed_e2e_run(project) do
    inserted_at = DateTime.add(IntakeSeed.base_time(), -15 * 60, :second)

    work_run =
      %WorkRun{}
      |> WorkRun.changeset(%{
        project_id: project.id,
        type: "linear_issue",
        status: "running",
        dedupe_key: "e2e-cod-1",
        linear_issue_id: "react-spa-e2e-1",
        linear_identifier: "COD-1",
        linear_url: "https://linear.app/harmony-e2e/issue/COD-1",
        agent_backend: "codex",
        payload: %{"title" => "Synchronizacja statusów zgłoszeń z Linear"}
      })
      |> Ecto.Changeset.put_change(:inserted_at, inserted_at)
      |> Ecto.Changeset.put_change(:updated_at, inserted_at)
      |> Repo.insert!()

    unless Storage.work_event_exists?(project.id, work_run.id, "run_started") do
      {:ok, _event} =
        Storage.append_event(%{
          project_id: project.id,
          work_run_id: work_run.id,
          type: "run_started",
          payload: %{message: "E2E run started"}
        })
    end

    seed_e2e_artifact(project, work_run)

    :ok
  end

  # Seeds a screenshot artifact for the COD-1 run so the Evidence tab has data.
  # The PNG file is written under the configured workspace root so that the
  # ArtifactController's containment check passes when serving the content.
  # Idempotent: skips insert if an artifact for this work_run already exists.
  defp seed_e2e_artifact(project, work_run) do
    existing = Storage.list_artifacts_for_work_run(work_run.id)

    if existing == [] do
      artifact_path = build_e2e_artifact_path(project)
      write_e2e_png!(artifact_path)

      {:ok, _artifact} =
        Storage.create_artifact(%{
          project_id: project.id,
          work_run_id: work_run.id,
          kind: "screenshot",
          path: artifact_path,
          metadata: %{}
        })
    end

    :ok
  end

  # Returns the absolute path for the e2e artifact PNG under the workspace root
  # of the synthetic workflow (a temporary directory of the harness).
  defp build_e2e_artifact_path(project) do
    {:ok, settings} = Config.settings()
    root = Path.expand(settings.workspace.root)

    dir = Path.join([root, "e2e-#{project.id}", ".harmony", "artifacts"])
    Path.join(dir, "e2e-screenshot.png")
  end

  # Writes a minimal valid 1×1 PNG to `path`, creating parent directories.
  # This is a hardcoded 68-byte 1×1 transparent PNG (no external deps).
  @minimal_png <<
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x02,
    0x00,
    0x00,
    0x00,
    0x90,
    0x77,
    0x53,
    0xDE,
    0x00,
    0x00,
    0x00,
    0x0C,
    0x49,
    0x44,
    0x41,
    0x54,
    0x08,
    0xD7,
    0x63,
    0xF8,
    0xCF,
    0xC0,
    0x00,
    0x00,
    0x00,
    0x02,
    0x00,
    0x01,
    0xE2,
    0x21,
    0xBC,
    0x33,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82
  >>

  defp write_e2e_png!(path) do
    :ok = File.mkdir_p!(Path.dirname(path))
    :ok = File.write!(path, @minimal_png)
  end

  defp unique_orchestrator_name do
    :"#{__MODULE__}.SnapshotOrchestrator.#{System.unique_integer([:positive])}"
  end

  defp install_runtime_guards do
    Application.put_env(:symphony_elixir, :work_source_fetchers, [])
    Application.put_env(:symphony_elixir, :workflow_file_path, write_e2e_workflow!())
  end

  # A synthetic workflow: no tracker token, no hooks, a temporary workspace
  # root, intake disabled at boot (no scheduler, no dispatcher) but manual
  # effects allowed so rule activation runs its read-only checks.
  defp write_e2e_workflow! do
    dir = Path.join(System.tmp_dir!(), "harmony-react-spa-e2e")
    path = Path.join(dir, "WORKFLOW.md")
    # The workspace root only holds the artifact PNG of the previous run.
    File.rm_rf!(Path.join(dir, "workspaces"))
    File.mkdir_p!(dir)

    File.write!(path, """
    ---
    tracker:
      kind: linear
      project_slugs:
        - react-spa-e2e
      active_states:
        - Todo
        - In Progress
      terminal_states:
        - Done
        - Canceled
    polling:
      interval_ms: 3600000
    workspace:
      root: #{Path.join(dir, "workspaces")}
    agent:
      max_concurrent_agents: 1
    intake:
      enabled: false
      effects_enabled: true
      public_url: https://harmony-e2e.example.test
      smtp_allowed_hosts:
        - smtp.e2e.example.test
    ---
    Synthetic React SPA E2E workflow; no agent is ever started.
    """)

    path
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

    # Handles stop_run/retry_now GenServer calls from RunActionController.
    #
    # The snapshot always includes the stable seeded entry (react-spa-e2e-1 /
    # COD-1), so RunActionController.find_issue_id/2 can resolve "COD-1" to its
    # issue_id and call stop_run/2 with "react-spa-e2e-1" here. We return :ok
    # for that seeded id and :run_not_found for anything else.
    #
    # retry_now is not exercised by the e2e suite (the seeded run is always
    # running, never retrying); return :not_retrying rather than crashing.
    def handle_call({:stop_run, issue_id}, _from, version) do
      running_ids = snapshot(version).running |> Enum.map(& &1.issue_id)

      if issue_id in running_ids do
        {:reply, :ok, version}
      else
        {:reply, {:error, :run_not_found}, version}
      end
    end

    def handle_call({:retry_now, _issue_id}, _from, version) do
      {:reply, {:error, :not_retrying}, version}
    end

    @impl true
    def handle_info(:broadcast_update, version) do
      :ok = SymphonyElixirWeb.ObservabilityPubSub.broadcast_update()
      {:noreply, version}
    end

    defp snapshot(version) do
      # The stable seeded entry (COD-1 / react-spa-e2e-1) is always present in
      # the running list so that RunActionController.find_issue_id/2 can resolve
      # "COD-1" to its issue_id regardless of how many /api/v1/refresh calls have
      # advanced the version counter. When version > 1 the refreshed entry
      # (COD-{version}) is prepended — the overview test asserts its appearance.
      running =
        if version > 1 do
          [running_entry(version), running_entry(1)]
        else
          [running_entry(version)]
        end

      %{
        running: running,
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
