defmodule SymphonyElixir.WorkRunApiTest do
  use SymphonyElixir.TestSupport

  import Ecto.Query
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint SymphonyElixirWeb.Endpoint

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

  setup do
    start_test_endpoint()
    :ok
  end

  # ===========================================================================
  # 404 — missing or unknown project param
  # ===========================================================================

  @tag :db
  test "returns 404 when project param is missing" do
    :ok = checkout_repo(%{})

    conn = get(build_conn(), "/api/v1/work_runs")
    body = json_response(conn, 404)
    assert body["error"]["code"] == "not_found"
  end

  @tag :db
  test "returns 404 for unknown project slug" do
    :ok = checkout_repo(%{})

    conn = get(build_conn(), "/api/v1/work_runs?project=does-not-exist")
    body = json_response(conn, 404)
    assert body["error"]["code"] == "not_found"
  end

  # ===========================================================================
  # 200 — basic pagination: 2 pages with cursor
  # ===========================================================================

  @tag :db
  test "returns first page with next_cursor and second page with no overlap" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    run1 = insert_work_run(project.id, %{linear_identifier: "COD-1"}) |> set_inserted_at(~U[2026-06-13 10:00:01.000000Z])
    run2 = insert_work_run(project.id, %{linear_identifier: "COD-2"}) |> set_inserted_at(~U[2026-06-13 10:00:02.000000Z])
    run3 = insert_work_run(project.id, %{linear_identifier: "COD-3"}) |> set_inserted_at(~U[2026-06-13 10:00:03.000000Z])

    # First page: page_size=2, should return run3 and run2 (newest first)
    conn = get(build_conn(), "/api/v1/work_runs?project=alpha&page_size=2")
    body = json_response(conn, 200)

    assert length(body["work_runs"]) == 2
    ids_page1 = Enum.map(body["work_runs"], & &1["id"])
    assert run3.id in ids_page1
    assert run2.id in ids_page1
    refute run1.id in ids_page1

    assert is_binary(body["meta"]["next_cursor"])
    assert body["meta"]["page_size"] == 2

    # Second page: use cursor from page 1
    cursor = body["meta"]["next_cursor"]
    conn2 = get(build_conn(), "/api/v1/work_runs?project=alpha&page_size=2&cursor=#{cursor}")
    body2 = json_response(conn2, 200)

    assert length(body2["work_runs"]) == 1
    assert hd(body2["work_runs"])["id"] == run1.id
    assert body2["meta"]["next_cursor"] == nil

    # No overlap between pages
    ids_page2 = Enum.map(body2["work_runs"], & &1["id"])
    assert Enum.empty?(ids_page1 -- (ids_page1 -- ids_page2))
  end

  # ===========================================================================
  # status filter
  # ===========================================================================

  @tag :db
  test "filters work runs by status" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    _queued = insert_work_run(project.id, %{status: "queued"})
    running1 = insert_work_run(project.id, %{status: "running"})
    running2 = insert_work_run(project.id, %{status: "running"})

    conn = get(build_conn(), "/api/v1/work_runs?project=alpha&status=running")
    body = json_response(conn, 200)

    ids = Enum.map(body["work_runs"], & &1["id"])
    assert running1.id in ids
    assert running2.id in ids
    assert Enum.all?(body["work_runs"], fn r -> r["status"] == "running" end)
  end

  # ===========================================================================
  # page_size cap at 100
  # ===========================================================================

  @tag :db
  test "caps page_size at 100 when requested value is higher" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    insert_work_run(project.id, %{})

    conn = get(build_conn(), "/api/v1/work_runs?project=alpha&page_size=500")
    body = json_response(conn, 200)

    assert body["meta"]["page_size"] == 100
  end

  # ===========================================================================
  # invalid page_size → default 25
  # ===========================================================================

  @tag :db
  test "uses default page_size of 25 for non-numeric page_size param" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    insert_work_run(project.id, %{})

    conn = get(build_conn(), "/api/v1/work_runs?project=alpha&page_size=abc")
    body = json_response(conn, 200)

    assert body["meta"]["page_size"] == 25
  end

  @tag :db
  test "uses default page_size of 25 when page_size param is absent" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    insert_work_run(project.id, %{})

    conn = get(build_conn(), "/api/v1/work_runs?project=alpha")
    body = json_response(conn, 200)

    assert body["meta"]["page_size"] == 25
  end

  # ===========================================================================
  # page_size with trailing non-numeric characters → default 25
  # ===========================================================================

  @tag :db
  test "uses default page_size of 25 for page_size param with trailing non-numeric chars (e.g. 5abc)" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    insert_work_run(project.id, %{})

    conn = get(build_conn(), "/api/v1/work_runs?project=alpha&page_size=5abc")
    body = json_response(conn, 200)

    assert body["meta"]["page_size"] == 25
  end

  # ===========================================================================
  # page_size floor at 1 for zero and negative values
  # ===========================================================================

  @tag :db
  test "floors page_size to 1 for zero and negative page_size params" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    insert_work_run(project.id, %{})

    conn_zero = get(build_conn(), "/api/v1/work_runs?project=alpha&page_size=0")
    body_zero = json_response(conn_zero, 200)
    assert body_zero["meta"]["page_size"] == 1

    conn_neg = get(build_conn(), "/api/v1/work_runs?project=alpha&page_size=-3")
    body_neg = json_response(conn_neg, 200)
    assert body_neg["meta"]["page_size"] == 1
  end

  # ===========================================================================
  # invalid cursor → behaves like first page (no cursor)
  # ===========================================================================

  @tag :db
  test "invalid cursor param behaves like first page (returns newest rows)" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    run1 = insert_work_run(project.id, %{linear_identifier: "COD-1"}) |> set_inserted_at(~U[2026-06-13 10:00:01.000000Z])
    run2 = insert_work_run(project.id, %{linear_identifier: "COD-2"}) |> set_inserted_at(~U[2026-06-13 10:00:02.000000Z])

    conn_no_cursor = get(build_conn(), "/api/v1/work_runs?project=alpha&page_size=10")
    body_no_cursor = json_response(conn_no_cursor, 200)

    conn_bad_cursor = get(build_conn(), "/api/v1/work_runs?project=alpha&page_size=10&cursor=!!!not-a-cursor!!!")
    body_bad_cursor = json_response(conn_bad_cursor, 200)

    ids_no_cursor = Enum.map(body_no_cursor["work_runs"], & &1["id"])
    ids_bad_cursor = Enum.map(body_bad_cursor["work_runs"], & &1["id"])

    assert run1.id in ids_bad_cursor
    assert run2.id in ids_bad_cursor
    assert ids_no_cursor == ids_bad_cursor
  end

  # ===========================================================================
  # results scoped to the requested project
  # ===========================================================================

  @tag :db
  test "returns only work runs belonging to the requested project" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    {:ok, other_project} =
      SymphonyElixir.Storage.upsert_project(%{
        slug: "beta",
        linear_project_slug: "beta-linear",
        linear_team_key: "BET",
        linear_human_review_state: "Human Review",
        forge_owner: "acme",
        forge_repo: "beta",
        forge_base_branch: "main",
        config_version: 1,
        config: %{}
      })

    my_run = insert_work_run(project.id, %{linear_identifier: "COD-1"})
    _other_run = insert_work_run(other_project.id, %{linear_identifier: "BET-1"})

    conn = get(build_conn(), "/api/v1/work_runs?project=alpha")
    body = json_response(conn, 200)

    ids = Enum.map(body["work_runs"], & &1["id"])
    assert my_run.id in ids
    assert Enum.all?(body["work_runs"], fn r -> r["project_id"] == project.id end)
  end

  # ===========================================================================
  # payload key absent from list items
  # ===========================================================================

  @tag :db
  test "does not expose the payload column in work run list items" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    insert_work_run(project.id, %{})

    conn = get(build_conn(), "/api/v1/work_runs?project=alpha")
    body = json_response(conn, 200)

    assert length(body["work_runs"]) >= 1
    assert Enum.all?(body["work_runs"], fn r -> not Map.has_key?(r, "payload") end)
  end

  # ===========================================================================
  # 405 method-not-allowed guard
  # ===========================================================================

  @tag :db
  test "returns 405 for non-GET methods on /api/v1/work_runs" do
    :ok = checkout_repo(%{})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/work_runs", "")

    body = json_response(conn, 405)
    assert body["error"]["code"] == "method_not_allowed"
  end

  # ===========================================================================
  # Shared-fixture contract: key sets must match
  # ===========================================================================

  @tag :db
  test "response key sets match the shared work_runs_page.fixture.json contract" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    run1 = insert_work_run(project.id, %{
      linear_identifier: "COD-1",
      linear_url: "https://linear.app/acme/issue/COD-1",
      forge_owner: "acme",
      forge_repo: "portal",
      forge_pr_number: 10,
      forge_head_sha: "abc123def456",
      forge_head_ref: "cod-1-feature",
      forge_base_ref: "main"
    }) |> set_inserted_at(~U[2026-06-13 10:00:02.000000Z])

    _run2 = insert_work_run(project.id, %{
      linear_identifier: "COD-2",
      linear_url: "https://linear.app/acme/issue/COD-2"
    }) |> set_inserted_at(~U[2026-06-13 10:00:01.000000Z])

    # Use page_size=1 so next_cursor is non-null (overfetch returns both, slices to 1)
    # Actually we seed 2 runs and request page_size=1 to get a non-null cursor
    conn = get(build_conn(), "/api/v1/work_runs?project=alpha&page_size=1")
    actual = json_response(conn, 200)

    # Ensure we got a non-null cursor (required by fixture contract)
    assert actual["meta"]["next_cursor"] != nil

    fixture_path =
      Path.expand(
        "../../assets/src/test/fixtures/work_runs_page.fixture.json",
        __DIR__
      )

    fixture = fixture_path |> File.read!() |> Jason.decode!()

    # Top-level keys must match.
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual)),
             MapSet.new(Map.keys(fixture))
           ),
           "Top-level keys mismatch.\nActual:  #{inspect(Map.keys(actual))}\nFixture: #{inspect(Map.keys(fixture))}"

    # meta keys must match.
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual["meta"])),
             MapSet.new(Map.keys(fixture["meta"]))
           ),
           "meta keys mismatch.\nActual:  #{inspect(Map.keys(actual["meta"]))}\nFixture: #{inspect(Map.keys(fixture["meta"]))}"

    # work_run item keys must match.
    assert [actual_run | _] = actual["work_runs"]
    assert [fixture_run | _] = fixture["work_runs"]

    assert MapSet.equal?(
             MapSet.new(Map.keys(actual_run)),
             MapSet.new(Map.keys(fixture_run))
           ),
           "work_run item keys mismatch.\nActual:  #{inspect(Map.keys(actual_run))}\nFixture: #{inspect(Map.keys(fixture_run))}"

    _ = run1
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

  defp set_inserted_at(run, inserted_at) do
    SymphonyElixir.Repo.update_all(
      from(r in SymphonyElixir.Storage.WorkRun, where: r.id == ^run.id),
      set: [inserted_at: inserted_at]
    )

    %{run | inserted_at: inserted_at}
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
