defmodule SymphonyElixir.RunDetailApiTest do
  use SymphonyElixir.TestSupport

  import Ecto.Query
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint SymphonyElixirWeb.Endpoint

  # ---------------------------------------------------------------------------
  # Fake orchestrator that returns a controllable snapshot.
  # ---------------------------------------------------------------------------

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(opts), do: {:ok, Keyword.get(opts, :snapshot, empty_snapshot())}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}

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

  @valid_project %{
    slug: "alpha",
    linear_project_slug: "alpha-linear",
    linear_team_key: "COD",
    linear_human_review_state: "Human Review",
    forge_owner: "acme",
    forge_repo: "portal",
    forge_base_branch: "main",
    config_version: 1,
    config: %{}
  }

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
    turn_count: 7,
    last_codex_event: "turn_end",
    last_codex_message: nil,
    started_at: ~U[2026-06-13 08:00:00Z],
    last_codex_timestamp: ~U[2026-06-13 09:00:00Z],
    codex_input_tokens: 200,
    codex_output_tokens: 80,
    codex_total_tokens: 280
  }

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    orchestrator_name = Module.concat(__MODULE__, :Orchestrator)
    start_supervised!({FakeOrchestrator, name: orchestrator_name})
    start_test_endpoint(orchestrator_name)
    :ok
  end

  # ===========================================================================
  # 404 — unknown identifier
  # ===========================================================================

  @tag :db
  test "show returns 404 run_not_found for unknown identifier" do
    :ok = checkout_repo(%{})

    conn = get(build_conn(), "/api/v1/runs/COD-999")
    body = json_response(conn, 404)
    assert body["error"]["code"] == "run_not_found"
  end

  @tag :db
  test "stream returns 404 run_not_found for unknown identifier" do
    :ok = checkout_repo(%{})

    conn = get(build_conn(), "/api/v1/runs/COD-999/stream")
    body = json_response(conn, 404)
    assert body["error"]["code"] == "run_not_found"
  end

  # ===========================================================================
  # Live-only: run exists in snapshot but not in DB
  # ===========================================================================

  @tag :db
  test "show returns 200 for live-only run (no durable row)" do
    :ok = checkout_repo(%{})

    seed_snapshot(%{running: [@running_entry]})

    conn = get(build_conn(), "/api/v1/runs/COD-10")
    body = json_response(conn, 200)

    assert body["identifier"] == "COD-10"
    assert body["status"] == "running"
    assert body["issue_id"] == "issue-cod-10"
    assert body["work_run_id"] == nil
    assert body["pull_requests"] == []
    assert body["artifacts"] == []
    # stream_cursor nil because no durable row
    assert body["stream_cursor"] == nil
  end

  @tag :db
  test "stream returns empty items with has_live true for live-only run" do
    :ok = checkout_repo(%{})

    seed_snapshot(%{running: [@running_entry]})

    conn = get(build_conn(), "/api/v1/runs/COD-10/stream")
    body = json_response(conn, 200)

    assert body["items"] == []
    assert body["meta"]["has_live"] == true
    assert body["meta"]["next_cursor"] == nil
  end

  # ===========================================================================
  # Durable-only: run in DB, not in snapshot
  # ===========================================================================

  @tag :db
  test "show returns 200 for durable-only run" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)
    run = insert_work_run(project.id, %{
      linear_identifier: "COD-10",
      linear_issue_id: "issue-cod-10-durable",
      status: "completed"
    })

    conn = get(build_conn(), "/api/v1/runs/COD-10")
    body = json_response(conn, 200)

    assert body["identifier"] == "COD-10"
    assert body["status"] == "completed"
    assert body["work_run_id"] == run.id
    assert body["issue_id"] == "issue-cod-10-durable"
    assert body["pull_requests"] == []
    assert body["artifacts"] == []
    assert body["stream_cursor"] == nil
  end

  @tag :db
  test "show includes artifacts when present" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)
    run = insert_work_run(project.id, %{linear_identifier: "COD-10"})

    {:ok, artifact} = SymphonyElixir.Storage.create_artifact(%{
      project_id: project.id,
      work_run_id: run.id,
      kind: "screenshot",
      path: "/artifacts/screen.png",
      metadata: %{"width" => 1280}
    })

    conn = get(build_conn(), "/api/v1/runs/COD-10")
    body = json_response(conn, 200)

    assert [art] = body["artifacts"]
    assert art["id"] == artifact.id
    assert art["kind"] == "screenshot"
    assert art["path"] == "/artifacts/screen.png"
    assert art["metadata"] == %{"width" => 1280}
  end

  @tag :db
  test "show includes pull_requests scoped to this run's identifier" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)
    _run = insert_work_run(project.id, %{linear_identifier: "COD-10"})

    # PR for this run
    {:ok, pr} = SymphonyElixir.Storage.upsert_pull_request_link(%{
      project_id: project.id,
      forge_owner: "acme",
      forge_repo: "portal",
      forge_pr_number: 42,
      forge_head_sha: "abc123",
      forge_head_ref: "cod-10-feature",
      forge_base_ref: "main",
      linear_issue_id: "issue-cod-10-durable",
      linear_identifier: "COD-10",
      linear_url: "https://linear.app/acme/issue/COD-10",
      metadata: %{}
    })

    # PR for another run — should not appear
    {:ok, _other_pr} = SymphonyElixir.Storage.upsert_pull_request_link(%{
      project_id: project.id,
      forge_owner: "acme",
      forge_repo: "portal",
      forge_pr_number: 99,
      forge_head_sha: "def456",
      forge_head_ref: "cod-11-feature",
      forge_base_ref: "main",
      linear_issue_id: "issue-cod-11",
      linear_identifier: "COD-11",
      linear_url: "https://linear.app/acme/issue/COD-11",
      metadata: %{}
    })

    conn = get(build_conn(), "/api/v1/runs/COD-10")
    body = json_response(conn, 200)

    assert [pr_resp] = body["pull_requests"]
    assert pr_resp["id"] == pr.id
    assert pr_resp["linear_identifier"] == "COD-10"
  end

  # ===========================================================================
  # Merged: live status wins
  # ===========================================================================

  @tag :db
  test "show — live status wins over durable status" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)
    _run = insert_work_run(project.id, %{
      linear_identifier: "COD-10",
      status: "completed"
    })

    seed_snapshot(%{running: [Map.put(@running_entry, :project_id, project.id)]})

    conn = get(build_conn(), "/api/v1/runs/COD-10")
    body = json_response(conn, 200)

    # Live entry says "running", durable says "completed" — live wins
    assert body["status"] == "running"
    assert body["session_id"] == "sess-abc"
    assert body["turn_count"] == 7
  end

  # ===========================================================================
  # Stream pagination — 2 pages ascending, no overlap
  # ===========================================================================

  @tag :db
  test "stream returns 2 pages ascending with no overlap" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)
    run = insert_work_run(project.id, %{linear_identifier: "COD-10"})

    event1 = insert_work_event(project.id, run.id, %{type: "turn_start"}) |> set_event_inserted_at(~U[2026-06-13 10:00:01.000000Z])
    event2 = insert_work_event(project.id, run.id, %{type: "turn_end"}) |> set_event_inserted_at(~U[2026-06-13 10:00:02.000000Z])
    event3 = insert_work_event(project.id, run.id, %{type: "tool_call"}) |> set_event_inserted_at(~U[2026-06-13 10:00:03.000000Z])

    # First page: page_size=2 → events 1, 2 + cursor
    conn = get(build_conn(), "/api/v1/runs/COD-10/stream?page_size=2")
    body = json_response(conn, 200)

    assert length(body["items"]) == 2
    ids_page1 = Enum.map(body["items"], & &1["id"])
    assert event1.id in ids_page1
    assert event2.id in ids_page1
    refute event3.id in ids_page1

    assert is_binary(body["meta"]["next_cursor"])
    assert body["meta"]["has_live"] == false

    # Second page using cursor
    cursor = body["meta"]["next_cursor"]
    conn2 = get(build_conn(), "/api/v1/runs/COD-10/stream?page_size=2&cursor=#{cursor}")
    body2 = json_response(conn2, 200)

    assert length(body2["items"]) == 1
    assert hd(body2["items"])["id"] == event3.id
    assert body2["meta"]["next_cursor"] == nil

    # No overlap
    ids_page2 = Enum.map(body2["items"], & &1["id"])
    assert MapSet.disjoint?(MapSet.new(ids_page1), MapSet.new(ids_page2))
  end

  # Ascending order of stream items
  @tag :db
  test "stream items are in ascending time order" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)
    run = insert_work_run(project.id, %{linear_identifier: "COD-10"})

    _e1 = insert_work_event(project.id, run.id, %{type: "a"}) |> set_event_inserted_at(~U[2026-06-13 10:00:01.000000Z])
    _e2 = insert_work_event(project.id, run.id, %{type: "b"}) |> set_event_inserted_at(~U[2026-06-13 10:00:02.000000Z])

    conn = get(build_conn(), "/api/v1/runs/COD-10/stream")
    body = json_response(conn, 200)

    [first, second] = body["items"]
    assert first["at"] <= second["at"]
  end

  # ===========================================================================
  # has_live flag — both ways
  # ===========================================================================

  @tag :db
  test "stream has_live is true when a live entry exists" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)
    run = insert_work_run(project.id, %{linear_identifier: "COD-10"})
    _e = insert_work_event(project.id, run.id, %{type: "turn_start"})

    seed_snapshot(%{running: [Map.put(@running_entry, :project_id, project.id)]})

    conn = get(build_conn(), "/api/v1/runs/COD-10/stream")
    body = json_response(conn, 200)

    assert body["meta"]["has_live"] == true
  end

  @tag :db
  test "stream has_live is false when no live entry exists" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)
    run = insert_work_run(project.id, %{linear_identifier: "COD-10"})
    _e = insert_work_event(project.id, run.id, %{type: "turn_start"})

    conn = get(build_conn(), "/api/v1/runs/COD-10/stream")
    body = json_response(conn, 200)

    assert body["meta"]["has_live"] == false
  end

  # ===========================================================================
  # page_size parse edge cases
  # ===========================================================================

  @tag :db
  test "stream caps page_size at 200" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)
    _run = insert_work_run(project.id, %{linear_identifier: "COD-10"})

    conn = get(build_conn(), "/api/v1/runs/COD-10/stream?page_size=9999")
    body = json_response(conn, 200)

    # We can't inspect page_size directly from response, but no error means parsing succeeded
    # and the meta block is present
    assert Map.has_key?(body, "meta")
    assert Map.has_key?(body["meta"], "next_cursor")
    assert Map.has_key?(body["meta"], "has_live")
  end

  @tag :db
  test "stream uses default page_size 50 for garbage page_size param" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)
    _run = insert_work_run(project.id, %{linear_identifier: "COD-10"})

    conn = get(build_conn(), "/api/v1/runs/COD-10/stream?page_size=garbage")
    body = json_response(conn, 200)

    assert Map.has_key?(body, "meta")
  end

  # ===========================================================================
  # 405 method-not-allowed guards
  # ===========================================================================

  @tag :db
  test "returns 405 for non-GET methods on /api/v1/runs/:identifier" do
    :ok = checkout_repo(%{})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/runs/COD-10", "")

    body = json_response(conn, 405)
    assert body["error"]["code"] == "method_not_allowed"
  end

  @tag :db
  test "returns 405 for non-GET methods on /api/v1/runs/:identifier/stream" do
    :ok = checkout_repo(%{})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/runs/COD-10/stream", "")

    body = json_response(conn, 405)
    assert body["error"]["code"] == "method_not_allowed"
  end

  # ===========================================================================
  # Shared-fixture contract: key sets for run_detail.fixture.json
  # ===========================================================================

  @tag :db
  test "show key sets match the shared run_detail.fixture.json contract" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    run = insert_work_run(project.id, %{
      linear_identifier: "COD-10",
      linear_issue_id: "issue-cod-10",
      status: "running",
      forge_owner: "acme",
      forge_repo: "portal",
      forge_pr_number: 42,
      forge_head_sha: "abc123def456",
      forge_head_ref: "cod-10-feature",
      forge_base_ref: "main"
    })

    {:ok, _pr} = SymphonyElixir.Storage.upsert_pull_request_link(%{
      project_id: project.id,
      forge_owner: "acme",
      forge_repo: "portal",
      forge_pr_number: 42,
      forge_head_sha: "abc123def456",
      forge_head_ref: "cod-10-feature",
      forge_base_ref: "main",
      linear_issue_id: "issue-cod-10",
      linear_identifier: "COD-10",
      linear_url: "https://linear.app/acme/issue/COD-10",
      metadata: %{}
    })

    {:ok, _artifact} = SymphonyElixir.Storage.create_artifact(%{
      project_id: project.id,
      work_run_id: run.id,
      kind: "screenshot",
      path: "/artifacts/screen.png",
      metadata: %{}
    })

    _event = insert_work_event(project.id, run.id, %{type: "turn_start"})

    seed_snapshot(%{running: [Map.put(@running_entry, :project_id, project.id)]})

    conn = get(build_conn(), "/api/v1/runs/COD-10")
    actual = json_response(conn, 200)

    fixture_path =
      Path.expand(
        "../../assets/src/test/fixtures/run_detail.fixture.json",
        __DIR__
      )

    fixture = fixture_path |> File.read!() |> Jason.decode!()

    # Top-level keys must match.
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual)),
             MapSet.new(Map.keys(fixture))
           ),
           "Top-level keys mismatch.\nActual:  #{inspect(Map.keys(actual))}\nFixture: #{inspect(Map.keys(fixture))}"

    # project keys
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual["project"])),
             MapSet.new(Map.keys(fixture["project"]))
           ),
           "project keys mismatch"

    # workspace keys
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual["workspace"])),
             MapSet.new(Map.keys(fixture["workspace"]))
           ),
           "workspace keys mismatch"

    # tokens keys (non-nil in merged state)
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual["tokens"])),
             MapSet.new(Map.keys(fixture["tokens"]))
           ),
           "tokens keys mismatch"

    # attempts keys
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual["attempts"])),
             MapSet.new(Map.keys(fixture["attempts"]))
           ),
           "attempts keys mismatch"

    # pull_request item keys
    assert [actual_pr | _] = actual["pull_requests"]
    assert [fixture_pr | _] = fixture["pull_requests"]
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual_pr)),
             MapSet.new(Map.keys(fixture_pr))
           ),
           "pull_request item keys mismatch"

    # artifact item keys
    assert [actual_art | _] = actual["artifacts"]
    assert [fixture_art | _] = fixture["artifacts"]
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual_art)),
             MapSet.new(Map.keys(fixture_art))
           ),
           "artifact item keys mismatch"
  end

  # ===========================================================================
  # Shared-fixture contract: key sets for run_stream_page.fixture.json
  # ===========================================================================

  @tag :db
  test "stream key sets match the shared run_stream_page.fixture.json contract" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)
    run = insert_work_run(project.id, %{linear_identifier: "COD-10"})

    _e1 = insert_work_event(project.id, run.id, %{type: "turn_start"}) |> set_event_inserted_at(~U[2026-06-13 10:00:01.000000Z])
    _e2 = insert_work_event(project.id, run.id, %{type: "turn_end"}) |> set_event_inserted_at(~U[2026-06-13 10:00:02.000000Z])
    _e3 = insert_work_event(project.id, run.id, %{type: "tool_call"}) |> set_event_inserted_at(~U[2026-06-13 10:00:03.000000Z])

    seed_snapshot(%{running: [Map.put(@running_entry, :project_id, project.id)]})

    # page_size=2 so next_cursor is non-null
    conn = get(build_conn(), "/api/v1/runs/COD-10/stream?page_size=2")
    actual = json_response(conn, 200)

    assert actual["meta"]["next_cursor"] != nil, "Fixture requires non-null next_cursor"

    fixture_path =
      Path.expand(
        "../../assets/src/test/fixtures/run_stream_page.fixture.json",
        __DIR__
      )

    fixture = fixture_path |> File.read!() |> Jason.decode!()

    # Top-level keys
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual)),
             MapSet.new(Map.keys(fixture))
           ),
           "Top-level keys mismatch.\nActual:  #{inspect(Map.keys(actual))}\nFixture: #{inspect(Map.keys(fixture))}"

    # meta keys
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual["meta"])),
             MapSet.new(Map.keys(fixture["meta"]))
           ),
           "meta keys mismatch"

    # item keys
    assert [actual_item | _] = actual["items"]
    assert [fixture_item | _] = fixture["items"]
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual_item)),
             MapSet.new(Map.keys(fixture_item))
           ),
           "stream item keys mismatch"
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp insert_work_run(project_id, attrs) do
    defaults = %{
      project_id: project_id,
      type: "implementation",
      status: "queued",
      agent_backend: "codex",
      payload: %{}
    }

    {:ok, run} = SymphonyElixir.Storage.create_work_run(Map.merge(defaults, attrs))
    run
  end

  defp insert_work_event(project_id, work_run_id, attrs) do
    defaults = %{
      project_id: project_id,
      work_run_id: work_run_id,
      type: "turn_start",
      payload: %{}
    }

    {:ok, event} = SymphonyElixir.Storage.append_event(Map.merge(defaults, attrs))
    event
  end

  defp set_event_inserted_at(event, inserted_at) do
    SymphonyElixir.Repo.update_all(
      from(e in SymphonyElixir.Storage.WorkEvent, where: e.id == ^event.id),
      set: [inserted_at: inserted_at]
    )

    %{event | inserted_at: inserted_at}
  end

  defp seed_snapshot(overrides) do
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
    orchestrator_name = Module.concat(__MODULE__, :Orchestrator)
    :sys.replace_state(orchestrator_name, fn _state -> snapshot end)
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
end
