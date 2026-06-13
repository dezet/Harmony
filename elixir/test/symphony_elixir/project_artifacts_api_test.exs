defmodule SymphonyElixir.ProjectArtifactsApiTest do
  @moduledoc """
  Integration tests for GET /api/v1/projects/:project_ref/artifacts.

  Covers:
  - 404 for unknown slug / UUID
  - artifact list shape (id, kind, metadata, work_run_id, work_run fields)
  - null work_run handled correctly when work_run_id is nil
  - `path` is never exposed in the response
  - 405 for non-GET methods
  - shared-fixture key-set contract
  """

  use SymphonyElixir.TestSupport

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
  # 404 — unknown references
  # ===========================================================================

  @tag :db
  test "returns 404 for an unknown slug" do
    :ok = checkout_repo(%{})

    conn = get(build_conn(), "/api/v1/projects/does-not-exist/artifacts")
    body = json_response(conn, 404)
    assert body["error"]["code"] == "not_found"
  end

  @tag :db
  test "returns 404 for an unknown UUID" do
    :ok = checkout_repo(%{})

    conn = get(build_conn(), "/api/v1/projects/00000000-0000-0000-0000-000000000000/artifacts")
    body = json_response(conn, 404)
    assert body["error"]["code"] == "not_found"
  end

  # ===========================================================================
  # 200 — empty list when project has no artifacts
  # ===========================================================================

  @tag :db
  test "returns empty artifacts list for a project with no artifacts" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/artifacts")
    body = json_response(conn, 200)

    assert body["artifacts"] == []
  end

  # ===========================================================================
  # 200 — artifact with work_run
  # ===========================================================================

  @tag :db
  test "returns artifact with inlined work_run fields when work_run_id is set" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    {:ok, run} = SymphonyElixir.Storage.create_work_run(%{
      project_id: project.id,
      type: "implementation",
      status: "completed",
      linear_identifier: "COD-42",
      agent_backend: "codex",
      payload: %{}
    })

    {:ok, artifact} = SymphonyElixir.Storage.create_artifact(%{
      project_id: project.id,
      work_run_id: run.id,
      kind: "screenshot",
      path: "/workspace/screenshot.png",
      metadata: %{"label" => "Homepage"}
    })

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/artifacts")
    body = json_response(conn, 200)

    assert [item] = body["artifacts"]
    assert item["id"] == artifact.id
    assert item["kind"] == "screenshot"
    assert item["metadata"] == %{"label" => "Homepage"}
    assert item["work_run_id"] == run.id

    assert %{
             "linear_identifier" => "COD-42",
             "status" => "completed",
             "inserted_at" => inserted_at_str
           } = item["work_run"]

    assert is_binary(inserted_at_str)
  end

  # ===========================================================================
  # 200 — artifact without work_run (work_run_id nil)
  # ===========================================================================

  @tag :db
  test "returns artifact with null work_run when work_run_id is nil" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    {:ok, artifact} = SymphonyElixir.Storage.create_artifact(%{
      project_id: project.id,
      work_run_id: nil,
      kind: "report",
      path: "/workspace/report.html",
      metadata: %{}
    })

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/artifacts")
    body = json_response(conn, 200)

    assert [item] = body["artifacts"]
    assert item["id"] == artifact.id
    assert item["work_run_id"] == nil
    assert item["work_run"] == nil
  end

  # ===========================================================================
  # path is never leaked in the response
  # ===========================================================================

  @tag :db
  test "does not expose the path field in artifact list items" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    {:ok, _artifact} = SymphonyElixir.Storage.create_artifact(%{
      project_id: project.id,
      work_run_id: nil,
      kind: "screenshot",
      path: "/workspace/secret.png",
      metadata: %{}
    })

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/artifacts")
    body = json_response(conn, 200)

    assert length(body["artifacts"]) >= 1
    assert Enum.all?(body["artifacts"], fn a -> not Map.has_key?(a, "path") end)
  end

  # ===========================================================================
  # 200 — multiple artifacts, both with and without work_run
  # ===========================================================================

  @tag :db
  test "returns multiple artifacts: one with work_run, one without" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    {:ok, run} = SymphonyElixir.Storage.create_work_run(%{
      project_id: project.id,
      type: "implementation",
      status: "completed",
      linear_identifier: "COD-42",
      agent_backend: "codex",
      payload: %{}
    })

    {:ok, _art1} = SymphonyElixir.Storage.create_artifact(%{
      project_id: project.id,
      work_run_id: run.id,
      kind: "screenshot",
      path: "/workspace/shot.png",
      metadata: %{"label" => "Homepage"}
    })

    {:ok, _art2} = SymphonyElixir.Storage.create_artifact(%{
      project_id: project.id,
      work_run_id: nil,
      kind: "report",
      path: "/workspace/report.html",
      metadata: %{}
    })

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/artifacts")
    body = json_response(conn, 200)

    assert length(body["artifacts"]) == 2

    screenshot = Enum.find(body["artifacts"], &(&1["kind"] == "screenshot"))
    report = Enum.find(body["artifacts"], &(&1["kind"] == "report"))

    assert screenshot["work_run_id"] == run.id
    assert is_map(screenshot["work_run"])
    assert screenshot["work_run"]["linear_identifier"] == "COD-42"

    assert report["work_run_id"] == nil
    assert report["work_run"] == nil
  end

  # ===========================================================================
  # 200 — resolves by UUID project_ref
  # ===========================================================================

  @tag :db
  test "resolves project by UUID and returns artifacts" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    conn = get(build_conn(), "/api/v1/projects/#{project.id}/artifacts")
    body = json_response(conn, 200)

    assert is_list(body["artifacts"])
  end

  # ===========================================================================
  # results scoped to the requested project
  # ===========================================================================

  @tag :db
  test "returns only artifacts belonging to the requested project" do
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

    {:ok, mine} = SymphonyElixir.Storage.create_artifact(%{
      project_id: project.id,
      work_run_id: nil,
      kind: "screenshot",
      path: "/workspace/mine.png",
      metadata: %{}
    })

    {:ok, _theirs} = SymphonyElixir.Storage.create_artifact(%{
      project_id: other_project.id,
      work_run_id: nil,
      kind: "screenshot",
      path: "/workspace/theirs.png",
      metadata: %{}
    })

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/artifacts")
    body = json_response(conn, 200)

    ids = Enum.map(body["artifacts"], & &1["id"])
    assert mine.id in ids
    assert length(ids) == 1
  end

  # ===========================================================================
  # 405 method-not-allowed guard
  # ===========================================================================

  @tag :db
  test "returns 405 for non-GET methods on the artifacts path" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/projects/#{project.slug}/artifacts", "")

    body = json_response(conn, 405)
    assert body["error"]["code"] == "method_not_allowed"
  end

  # ===========================================================================
  # Shared-fixture contract: key sets must match
  # ===========================================================================

  @tag :db
  test "response key sets match the shared project_artifacts_page.fixture.json contract" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    {:ok, run} = SymphonyElixir.Storage.create_work_run(%{
      project_id: project.id,
      type: "implementation",
      status: "completed",
      linear_identifier: "COD-42",
      agent_backend: "codex",
      payload: %{}
    })

    # Artifact with work_run
    {:ok, _art1} = SymphonyElixir.Storage.create_artifact(%{
      project_id: project.id,
      work_run_id: run.id,
      kind: "screenshot",
      path: "/workspace/shot.png",
      metadata: %{"label" => "Homepage"}
    })

    # Artifact without work_run
    {:ok, _art2} = SymphonyElixir.Storage.create_artifact(%{
      project_id: project.id,
      work_run_id: nil,
      kind: "report",
      path: "/workspace/report.html",
      metadata: %{}
    })

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/artifacts")
    actual = json_response(conn, 200)

    fixture_path =
      Path.expand(
        "../../assets/src/test/fixtures/project_artifacts_page.fixture.json",
        __DIR__
      )

    fixture = fixture_path |> File.read!() |> Jason.decode!()

    # Top-level keys must match.
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual)),
             MapSet.new(Map.keys(fixture))
           ),
           "Top-level keys mismatch.\nActual:  #{inspect(Map.keys(actual))}\nFixture: #{inspect(Map.keys(fixture))}"

    # Artifact item keys must match (compare against the first fixture artifact which has work_run).
    [fixture_with_run | _] = fixture["artifacts"]
    actual_with_run = Enum.find(actual["artifacts"], &(not is_nil(&1["work_run_id"])))

    assert MapSet.equal?(
             MapSet.new(Map.keys(actual_with_run)),
             MapSet.new(Map.keys(fixture_with_run))
           ),
           "artifact item keys mismatch.\nActual:  #{inspect(Map.keys(actual_with_run))}\nFixture: #{inspect(Map.keys(fixture_with_run))}"

    # work_run sub-object keys must match.
    assert MapSet.equal?(
             MapSet.new(Map.keys(actual_with_run["work_run"])),
             MapSet.new(Map.keys(fixture_with_run["work_run"]))
           ),
           "work_run sub-object keys mismatch.\nActual:  #{inspect(Map.keys(actual_with_run["work_run"]))}\nFixture: #{inspect(Map.keys(fixture_with_run["work_run"]))}"
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
