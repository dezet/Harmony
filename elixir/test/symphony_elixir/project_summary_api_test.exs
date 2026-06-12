defmodule SymphonyElixir.ProjectSummaryApiTest do
  use SymphonyElixir.TestSupport

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
  # Project attributes used across tests
  # ---------------------------------------------------------------------------

  @valid_project %{
    slug: "alpha",
    linear_project_slug: "alpha-linear",
    linear_team_key: "COD",
    linear_human_review_state: "Human Review",
    github_owner: "acme",
    github_repo: "portal",
    github_base_branch: "main",
    config_version: 3,
    config: %{}
  }

  # ---------------------------------------------------------------------------
  # Setup: start a fake orchestrator and a test endpoint wired to it.
  # ---------------------------------------------------------------------------

  setup do
    orchestrator_name = Module.concat(__MODULE__, :Orchestrator)
    start_supervised!({FakeOrchestrator, name: orchestrator_name})
    start_test_endpoint(orchestrator_name)
    :ok
  end

  # ===========================================================================
  # 404 tests (no DB rows needed — snapshot is empty, project not found)
  # ===========================================================================

  @tag :db
  test "returns 404 for an unknown slug" do
    :ok = checkout_repo(%{})

    conn = get(build_conn(), "/api/v1/projects/does-not-exist/summary")
    body = json_response(conn, 404)
    assert body["error"]["code"] == "not_found"
  end

  @tag :db
  test "returns 404 for an unknown UUID" do
    :ok = checkout_repo(%{})

    conn = get(build_conn(), "/api/v1/projects/00000000-0000-0000-0000-000000000000/summary")
    body = json_response(conn, 404)
    assert body["error"]["code"] == "not_found"
  end

  # ===========================================================================
  # 200 — resolves by slug
  # ===========================================================================

  @tag :db
  test "resolves by slug and returns 200 with project block" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/summary")
    body = json_response(conn, 200)

    assert body["project"]["id"] == project.id
    assert body["project"]["slug"] == "alpha"
    assert body["project"]["github_owner"] == "acme"
    assert body["project"]["github_repo"] == "portal"
    assert body["project"]["github_base_branch"] == "main"
    assert body["project"]["linear_project_slug"] == "alpha-linear"
    assert body["project"]["linear_team_key"] == "COD"
    assert body["project"]["linear_human_review_state"] == "Human Review"
    assert body["project"]["config_version"] == 3
  end

  # ===========================================================================
  # 200 — resolves by UUID
  # ===========================================================================

  @tag :db
  test "resolves UUID-shaped slug by slug when no project has that id" do
    :ok = checkout_repo(%{})

    uuid_slug = "550e8400-e29b-41d4-a716-446655440000"

    {:ok, project} =
      SymphonyElixir.Storage.upsert_project(Map.put(@valid_project, :slug, uuid_slug))

    # The project's actual id is different from uuid_slug, so a UUID-id lookup
    # must miss and fall back to a slug lookup.
    refute project.id == uuid_slug

    conn = get(build_conn(), "/api/v1/projects/#{uuid_slug}/summary")
    body = json_response(conn, 200)

    assert body["project"]["id"] == project.id
    assert body["project"]["slug"] == uuid_slug
  end

  @tag :db
  test "resolves by UUID and returns 200 with project block" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    conn = get(build_conn(), "/api/v1/projects/#{project.id}/summary")
    body = json_response(conn, 200)

    assert body["project"]["id"] == project.id
    assert body["project"]["slug"] == "alpha"
  end

  # ===========================================================================
  # 200 — live entries filtered to the project
  # ===========================================================================

  @tag :db
  test "includes live running/retrying/blocked entries belonging to the project" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    # Seed the fake orchestrator with entries for this project and another project.
    running_entry = %{
      issue_id: "issue-running-1",
      identifier: "COD-10",
      state: "running",
      project_id: project.id,
      project_name: "Alpha",
      project_slug: "alpha",
      worker_host: "host1",
      workspace_path: "/ws/cod-10",
      session_id: "sess-1",
      turn_count: 5,
      last_codex_event: "turn_end",
      last_codex_message: nil,
      started_at: ~U[2026-06-10 08:00:00Z],
      last_codex_timestamp: ~U[2026-06-10 09:00:00Z],
      codex_input_tokens: 100,
      codex_output_tokens: 50,
      codex_total_tokens: 150
    }

    retry_entry = %{
      issue_id: "issue-retry-1",
      identifier: "COD-11",
      project_id: project.id,
      project_name: "Alpha",
      project_slug: "alpha",
      attempt: 2,
      due_in_ms: 60_000,
      error: "some error",
      worker_host: "host1",
      workspace_path: "/ws/cod-11"
    }

    blocked_entry = %{
      issue_id: "issue-blocked-1",
      identifier: "COD-12",
      state: "blocked",
      project_id: project.id,
      project_name: "Alpha",
      project_slug: "alpha",
      error: "human review required",
      worker_host: "host1",
      workspace_path: "/ws/cod-12",
      session_id: "sess-2",
      blocked_at: ~U[2026-06-10 10:00:00Z],
      last_codex_event: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil
    }

    other_entry = %{
      issue_id: "issue-other-1",
      identifier: "OTH-1",
      state: "running",
      project_id: "proj-uuid-OTHER",
      project_name: "Other",
      project_slug: "other",
      worker_host: "host2",
      workspace_path: "/ws/oth-1",
      session_id: "sess-other",
      turn_count: 1,
      last_codex_event: nil,
      last_codex_message: nil,
      started_at: ~U[2026-06-10 08:00:00Z],
      last_codex_timestamp: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0
    }

    snapshot = %{
      running: [running_entry, other_entry],
      retrying: [retry_entry],
      blocked: [blocked_entry],
      runtime: %{},
      artifacts: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: %{}
    }

    # Push the snapshot into the fake orchestrator.
    orchestrator_name = Module.concat(__MODULE__, :Orchestrator)
    :sys.replace_state(orchestrator_name, fn _state -> snapshot end)

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/summary")
    body = json_response(conn, 200)

    assert body["counts"] == %{"running" => 1, "retrying" => 1, "blocked" => 1}

    assert length(body["running"]) == 1
    assert hd(body["running"])["issue_identifier"] == "COD-10"
    refute Map.has_key?(hd(body["running"]), "project")

    assert length(body["retrying"]) == 1
    assert hd(body["retrying"])["issue_identifier"] == "COD-11"
    refute Map.has_key?(hd(body["retrying"]), "project")

    assert length(body["blocked"]) == 1
    assert hd(body["blocked"])["issue_identifier"] == "COD-12"
    refute Map.has_key?(hd(body["blocked"]), "project")
  end

  # ===========================================================================
  # 200 — human_review_prs present with expected fields
  # ===========================================================================

  @tag :db
  test "includes human_review_prs with expected fields" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    {:ok, _pr} =
      SymphonyElixir.Storage.upsert_pull_request_link(%{
        project_id: project.id,
        github_owner: "acme",
        github_repo: "portal",
        github_pr_number: 42,
        github_head_sha: "abc123",
        github_head_ref: "cod-10-feature",
        github_base_ref: "main",
        linear_issue_id: "issue-running-1",
        linear_identifier: "COD-10",
        linear_url: "https://linear.app/acme/issue/COD-10",
        metadata: %{"ci_status" => "pass"}
      })

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/summary")
    body = json_response(conn, 200)

    assert [pr] = body["human_review_prs"]
    assert pr["github_owner"] == "acme"
    assert pr["github_repo"] == "portal"
    assert pr["github_pr_number"] == 42
    assert pr["github_head_sha"] == "abc123"
    assert pr["github_head_ref"] == "cod-10-feature"
    assert pr["github_base_ref"] == "main"
    assert pr["linear_identifier"] == "COD-10"
    assert pr["linear_url"] == "https://linear.app/acme/issue/COD-10"
    assert pr["metadata"] == %{"ci_status" => "pass"}
    assert is_binary(pr["id"])
  end

  # ===========================================================================
  # 405 method-not-allowed guard
  # ===========================================================================

  @tag :db
  test "returns 405 for non-GET methods on the summary path" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/projects/#{project.slug}/summary", "")

    body = json_response(conn, 405)
    assert body["error"]["code"] == "method_not_allowed"
  end

  # ===========================================================================
  # Shared-fixture contract: key sets must match
  # ===========================================================================

  @tag :db
  test "response key sets match the shared project_summary.fixture.json contract" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    # Seed a PR link so human_review_prs is non-empty.
    {:ok, _pr} =
      SymphonyElixir.Storage.upsert_pull_request_link(%{
        project_id: project.id,
        github_owner: "acme",
        github_repo: "portal",
        github_pr_number: 42,
        github_head_sha: "abc123def456",
        github_head_ref: "cod-10-feature",
        github_base_ref: "main",
        linear_issue_id: "issue-running-1",
        linear_identifier: "COD-10",
        linear_url: "https://linear.app/acme/issue/COD-10",
        metadata: %{"ci_status" => "pass"}
      })

    # Seed the orchestrator with one entry per status.
    running_entry = %{
      issue_id: "issue-running-1",
      identifier: "COD-10",
      state: "running",
      project_id: project.id,
      project_name: "Alpha",
      project_slug: "alpha",
      worker_host: "host1",
      workspace_path: "/ws/cod-10",
      session_id: "sess-1",
      turn_count: 5,
      last_codex_event: "turn_end",
      last_codex_message: nil,
      started_at: ~U[2026-06-10 08:00:00Z],
      last_codex_timestamp: ~U[2026-06-10 09:00:00Z],
      codex_input_tokens: 100,
      codex_output_tokens: 50,
      codex_total_tokens: 150
    }

    retry_entry = %{
      issue_id: "issue-retry-1",
      identifier: "COD-11",
      project_id: project.id,
      project_name: "Alpha",
      project_slug: "alpha",
      attempt: 2,
      due_in_ms: 60_000,
      error: "some error",
      worker_host: "host1",
      workspace_path: "/ws/cod-11"
    }

    blocked_entry = %{
      issue_id: "issue-blocked-1",
      identifier: "COD-12",
      state: "blocked",
      project_id: project.id,
      project_name: "Alpha",
      project_slug: "alpha",
      error: "human review required",
      worker_host: "host1",
      workspace_path: "/ws/cod-12",
      session_id: "sess-2",
      blocked_at: ~U[2026-06-10 10:00:00Z],
      last_codex_event: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil
    }

    snapshot = %{
      running: [running_entry],
      retrying: [retry_entry],
      blocked: [blocked_entry],
      runtime: %{},
      artifacts: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: %{}
    }

    orchestrator_name = Module.concat(__MODULE__, :Orchestrator)
    :sys.replace_state(orchestrator_name, fn _state -> snapshot end)

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/summary")
    actual = json_response(conn, 200)

    # Load the shared fixture.
    fixture_path =
      Path.expand(
        "../../assets/src/test/fixtures/project_summary.fixture.json",
        __DIR__
      )

    fixture = fixture_path |> File.read!() |> Jason.decode!()

    # Top-level keys must match.
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual)),
             MapSet.new(Map.keys(fixture))
           ),
           "Top-level keys mismatch.\nActual:  #{inspect(Map.keys(actual))}\nFixture: #{inspect(Map.keys(fixture))}"

    # Project block keys.
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual["project"])),
             MapSet.new(Map.keys(fixture["project"]))
           ),
           "project keys mismatch"

    # Running entry keys.
    assert [actual_running] = actual["running"]
    assert [fixture_running] = fixture["running"]

    assert MapSet.equal?(
             MapSet.new(Map.keys(actual_running)),
             MapSet.new(Map.keys(fixture_running))
           ),
           "running entry keys mismatch.\nActual:  #{inspect(Map.keys(actual_running))}\nFixture: #{inspect(Map.keys(fixture_running))}"

    # Retrying entry keys.
    assert [actual_retrying] = actual["retrying"]
    assert [fixture_retrying] = fixture["retrying"]

    assert MapSet.equal?(
             MapSet.new(Map.keys(actual_retrying)),
             MapSet.new(Map.keys(fixture_retrying))
           ),
           "retrying entry keys mismatch.\nActual:  #{inspect(Map.keys(actual_retrying))}\nFixture: #{inspect(Map.keys(fixture_retrying))}"

    # Blocked entry keys.
    assert [actual_blocked] = actual["blocked"]
    assert [fixture_blocked] = fixture["blocked"]

    assert MapSet.equal?(
             MapSet.new(Map.keys(actual_blocked)),
             MapSet.new(Map.keys(fixture_blocked))
           ),
           "blocked entry keys mismatch.\nActual:  #{inspect(Map.keys(actual_blocked))}\nFixture: #{inspect(Map.keys(fixture_blocked))}"

    # PR link keys.
    assert [actual_pr] = actual["human_review_prs"]
    assert [fixture_pr] = fixture["human_review_prs"]

    assert MapSet.equal?(
             MapSet.new(Map.keys(actual_pr)),
             MapSet.new(Map.keys(fixture_pr))
           ),
           "human_review_pr keys mismatch.\nActual:  #{inspect(Map.keys(actual_pr))}\nFixture: #{inspect(Map.keys(fixture_pr))}"
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

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
