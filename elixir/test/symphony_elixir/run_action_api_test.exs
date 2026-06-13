defmodule SymphonyElixir.RunActionApiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint SymphonyElixirWeb.Endpoint

  # ---------------------------------------------------------------------------
  # Fake orchestrator: handles snapshot, stop_run, and retry_now calls.
  # State shape: %{snapshot: map(), stop_results: %{issue_id => result},
  #                retry_results: %{issue_id => result}}
  # ---------------------------------------------------------------------------

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(opts) do
      state = %{
        snapshot: Keyword.get(opts, :snapshot, empty_snapshot()),
        stop_results: Keyword.get(opts, :stop_results, %{}),
        retry_results: Keyword.get(opts, :retry_results, %{})
      }

      {:ok, state}
    end

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

    def handle_call({:stop_run, issue_id}, _from, state) do
      result = Map.get(state.stop_results, issue_id, {:error, :run_not_found})
      {:reply, result, state}
    end

    def handle_call({:retry_now, issue_id}, _from, state) do
      result = Map.get(state.retry_results, issue_id, {:error, :not_retrying})
      {:reply, result, state}
    end

    defp empty_snapshot do
      %{
        running: [],
        retrying: [],
        blocked: [],
        runtime: %{},
        artifacts: [],
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        rate_limits: %{}
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Common fixtures
  # ---------------------------------------------------------------------------

  @running_entry %{
    issue_id: "issue-cod-10",
    identifier: "COD-10",
    state: "running",
    project_id: nil,
    project_name: "Alpha",
    project_slug: "alpha",
    worker_host: "host1",
    workspace_path: "/ws/cod-10",
    session_id: "sess-abc",
    turn_count: 3,
    last_codex_event: "turn_end",
    last_codex_message: nil,
    started_at: ~U[2026-06-13 08:00:00Z],
    last_codex_timestamp: ~U[2026-06-13 09:00:00Z],
    codex_input_tokens: 100,
    codex_output_tokens: 50,
    codex_total_tokens: 150
  }

  @retrying_entry %{
    issue_id: "issue-cod-20",
    identifier: "COD-20",
    attempt: 2,
    due_in_ms: 5000,
    project_id: nil,
    project_name: "Alpha",
    project_slug: "alpha",
    error: "agent exited: :shutdown",
    worker_host: "host1",
    workspace_path: "/ws/cod-20"
  }

  @blocked_entry %{
    issue_id: "issue-cod-30",
    identifier: "COD-30",
    project_id: nil,
    project_name: "Alpha",
    project_slug: "alpha",
    state: "In Progress",
    worker_host: "host1",
    workspace_path: "/ws/cod-30",
    session_id: "sess-blocked",
    error: "codex turn requires operator input",
    blocked_at: ~U[2026-06-13 09:00:00Z],
    last_codex_timestamp: ~U[2026-06-13 09:00:00Z],
    last_codex_message: nil,
    last_codex_event: :turn_input_required
  }

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    orchestrator_name = Module.concat(__MODULE__, :Orchestrator)
    :ok
    {:ok, orchestrator_name: orchestrator_name}
  end

  defp start_orchestrator(orchestrator_name, opts \\ []) do
    start_supervised!({FakeOrchestrator, Keyword.merge([name: orchestrator_name], opts)})
  end

  defp start_test_endpoint(orchestrator_name) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        orchestrator: orchestrator_name
      )

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp seed_snapshot(orchestrator_name, overrides) do
    base = %{
      running: [],
      retrying: [],
      blocked: [],
      runtime: %{},
      artifacts: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: %{}
    }

    snapshot = Map.merge(base, overrides)
    :sys.replace_state(orchestrator_name, fn state -> %{state | snapshot: snapshot} end)
  end

  defp set_stop_result(orchestrator_name, issue_id, result) do
    :sys.replace_state(orchestrator_name, fn state ->
      %{state | stop_results: Map.put(state.stop_results, issue_id, result)}
    end)
  end

  defp set_retry_result(orchestrator_name, issue_id, result) do
    :sys.replace_state(orchestrator_name, fn state ->
      %{state | retry_results: Map.put(state.retry_results, issue_id, result)}
    end)
  end

  # ===========================================================================
  # stop — 200 stopped
  # ===========================================================================

  test "stop on a running entry returns 200 with status stopped", %{orchestrator_name: name} do
    start_orchestrator(name)
    start_test_endpoint(name)

    seed_snapshot(name, %{running: [@running_entry]})
    set_stop_result(name, "issue-cod-10", :ok)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/runs/COD-10/stop", "")

    body = json_response(conn, 200)
    assert body["status"] == "stopped"
  end

  # ===========================================================================
  # retry — 200 retrying
  # ===========================================================================

  test "retry on a retrying entry returns 200 with status retrying", %{orchestrator_name: name} do
    start_orchestrator(name)
    start_test_endpoint(name)

    seed_snapshot(name, %{retrying: [@retrying_entry]})
    set_retry_result(name, "issue-cod-20", :ok)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/runs/COD-20/retry", "")

    body = json_response(conn, 200)
    assert body["status"] == "retrying"
  end

  # ===========================================================================
  # 404 — unknown identifier
  # ===========================================================================

  test "stop on unknown identifier returns 404 run_not_found", %{orchestrator_name: name} do
    start_orchestrator(name)
    start_test_endpoint(name)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/runs/COD-999/stop", "")

    body = json_response(conn, 404)
    assert body["error"]["code"] == "run_not_found"
  end

  test "retry on unknown identifier returns 404 run_not_found", %{orchestrator_name: name} do
    start_orchestrator(name)
    start_test_endpoint(name)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/runs/COD-999/retry", "")

    body = json_response(conn, 404)
    assert body["error"]["code"] == "run_not_found"
  end

  # ===========================================================================
  # 409 — already_terminal
  # ===========================================================================

  test "stop on completed run returns 409 already_terminal", %{orchestrator_name: name} do
    start_orchestrator(name)
    start_test_endpoint(name)

    # Entry is visible in snapshot so identifier→issue_id resolution succeeds,
    # but the orchestrator reports the run is already terminal.
    seed_snapshot(name, %{running: [@running_entry]})
    set_stop_result(name, "issue-cod-10", {:error, :already_terminal})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/runs/COD-10/stop", "")

    body = json_response(conn, 409)
    assert body["error"]["code"] == "already_terminal"
  end

  # ===========================================================================
  # 409 — not_retrying
  # ===========================================================================

  test "retry on a running (non-retrying) entry returns 409 not_retrying", %{orchestrator_name: name} do
    start_orchestrator(name)
    start_test_endpoint(name)

    # Entry is running (not in retry_attempts), so retry_now returns :not_retrying.
    seed_snapshot(name, %{running: [@running_entry]})
    set_retry_result(name, "issue-cod-10", {:error, :not_retrying})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/runs/COD-10/retry", "")

    body = json_response(conn, 409)
    assert body["error"]["code"] == "not_retrying"
  end

  # ===========================================================================
  # stop on blocked entry — 200 stopped
  # ===========================================================================

  test "stop on a blocked entry finds issue_id and returns 200 stopped", %{orchestrator_name: name} do
    start_orchestrator(name)
    start_test_endpoint(name)

    seed_snapshot(name, %{blocked: [@blocked_entry]})
    set_stop_result(name, "issue-cod-30", :ok)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/runs/COD-30/stop", "")

    body = json_response(conn, 200)
    assert body["status"] == "stopped"
  end

  # ===========================================================================
  # 405 — GET on stop/retry paths
  # ===========================================================================

  test "GET on /stop returns 405 method_not_allowed", %{orchestrator_name: name} do
    start_orchestrator(name)
    start_test_endpoint(name)

    conn = get(build_conn(), "/api/v1/runs/COD-10/stop")
    body = json_response(conn, 405)
    assert body["error"]["code"] == "method_not_allowed"
  end

  test "GET on /retry returns 405 method_not_allowed", %{orchestrator_name: name} do
    start_orchestrator(name)
    start_test_endpoint(name)

    conn = get(build_conn(), "/api/v1/runs/COD-10/retry")
    body = json_response(conn, 405)
    assert body["error"]["code"] == "method_not_allowed"
  end
end
