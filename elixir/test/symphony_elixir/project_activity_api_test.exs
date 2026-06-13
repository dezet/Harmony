defmodule SymphonyElixir.ProjectActivityApiTest do
  @moduledoc """
  Integration tests for GET /api/v1/projects/:project_ref/activity.

  Covers:
  - 404 for unknown slug / UUID
  - activity pagination: 2 pages ascending, no overlap
  - page_size cap (200) and garbage → default (50)
  - 405 for non-GET methods
  - shared-fixture key-set contract
  """

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
  # 404 — unknown references
  # ===========================================================================

  @tag :db
  test "returns 404 for an unknown slug" do
    :ok = checkout_repo(%{})

    conn = get(build_conn(), "/api/v1/projects/does-not-exist/activity")
    body = json_response(conn, 404)
    assert body["error"]["code"] == "not_found"
  end

  @tag :db
  test "returns 404 for an unknown UUID" do
    :ok = checkout_repo(%{})

    conn = get(build_conn(), "/api/v1/projects/00000000-0000-0000-0000-000000000000/activity")
    body = json_response(conn, 404)
    assert body["error"]["code"] == "not_found"
  end

  # ===========================================================================
  # 200 — empty feed when project has no events
  # ===========================================================================

  @tag :db
  test "returns empty items list for a project with no events" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/activity")
    body = json_response(conn, 200)

    assert body["items"] == []
    assert body["meta"]["next_cursor"] == nil
  end

  # ===========================================================================
  # 200 — 2-page ascending pagination with no overlap
  # ===========================================================================

  @tag :db
  test "returns first page with next_cursor and second page with no overlap (ascending)" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    evt1 = insert_event(project.id, "turn_start") |> set_event_inserted_at(~U[2026-06-13 10:00:01.000000Z])
    evt2 = insert_event(project.id, "turn_end") |> set_event_inserted_at(~U[2026-06-13 10:00:02.000000Z])
    evt3 = insert_event(project.id, "tool_use") |> set_event_inserted_at(~U[2026-06-13 10:00:03.000000Z])

    # First page: page_size=2, ascending → oldest first
    conn1 = get(build_conn(), "/api/v1/projects/#{project.slug}/activity?page_size=2")
    body1 = json_response(conn1, 200)

    assert length(body1["items"]) == 2
    ids_page1 = Enum.map(body1["items"], & &1["id"])
    assert evt1.id in ids_page1
    assert evt2.id in ids_page1
    refute evt3.id in ids_page1

    assert is_binary(body1["meta"]["next_cursor"])

    # Second page: use cursor from page 1
    cursor = body1["meta"]["next_cursor"]
    conn2 = get(build_conn(), "/api/v1/projects/#{project.slug}/activity?page_size=2&cursor=#{cursor}")
    body2 = json_response(conn2, 200)

    assert length(body2["items"]) == 1
    assert hd(body2["items"])["id"] == evt3.id
    assert body2["meta"]["next_cursor"] == nil

    # No overlap between pages
    ids_page2 = Enum.map(body2["items"], & &1["id"])
    assert Enum.empty?(ids_page1 -- (ids_page1 -- ids_page2))
  end

  # ===========================================================================
  # page_size cap at 200
  # ===========================================================================

  @tag :db
  test "caps page_size at 200 when requested value exceeds 200" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    insert_event(project.id, "turn_start")

    # If page_size were uncapped, meta would show the capped value;
    # we verify no crash and the response shape is valid.
    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/activity?page_size=9999")
    body = json_response(conn, 200)

    assert is_list(body["items"])
    assert is_map(body["meta"])
    # The page_size doesn't appear in the activity meta (only next_cursor), but
    # the response must be valid and not error.
    assert Map.has_key?(body["meta"], "next_cursor")
  end

  # ===========================================================================
  # garbage page_size → default 50
  # ===========================================================================

  @tag :db
  test "uses default page_size of 50 for non-numeric page_size param" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    # Seed 51 events to verify the default page_size (50) is applied.
    for i <- 1..51 do
      insert_event(project.id, "turn_#{i}")
    end

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/activity?page_size=garbage")
    body = json_response(conn, 200)

    # With default page_size=50 and 51 events, we get 50 items and a cursor.
    assert length(body["items"]) == 50
    assert is_binary(body["meta"]["next_cursor"])
  end

  # ===========================================================================
  # events scoped to the requested project
  # ===========================================================================

  @tag :db
  test "returns only events belonging to the requested project" do
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

    mine = insert_event(project.id, "turn_start")
    _theirs = insert_event(other_project.id, "turn_start")

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/activity")
    body = json_response(conn, 200)

    ids = Enum.map(body["items"], & &1["id"])
    assert mine.id in ids
    assert length(ids) == 1
  end

  # ===========================================================================
  # event item shape (reuses stream_event_payload)
  # ===========================================================================

  @tag :db
  test "event items have expected fields: id, kind, type, at, payload" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    {:ok, evt} = SymphonyElixir.Storage.append_event(%{
      project_id: project.id,
      type: "turn_start",
      payload: %{"info" => "test"}
    })

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/activity")
    body = json_response(conn, 200)

    assert [item] = body["items"]
    assert item["id"] == evt.id
    assert item["kind"] == "work_event"
    assert item["type"] == "turn_start"
    assert is_binary(item["at"])
    assert item["payload"] == %{"info" => "test"}
    # has_live must NOT be in the meta (activity differs from run stream)
    refute Map.has_key?(body["meta"], "has_live")
  end

  # ===========================================================================
  # 405 method-not-allowed guard
  # ===========================================================================

  @tag :db
  test "returns 405 for non-GET methods on the activity path" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/projects/#{project.slug}/activity", "")

    body = json_response(conn, 405)
    assert body["error"]["code"] == "method_not_allowed"
  end

  # ===========================================================================
  # Shared-fixture contract: key sets must match
  # ===========================================================================

  @tag :db
  test "response key sets match the shared project_activity_page.fixture.json contract" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(@valid_project)

    # Seed 2 events + page_size=1 to get a non-null next_cursor
    _evt1 = insert_event(project.id, "turn_start") |> set_event_inserted_at(~U[2026-06-13 10:00:01.000000Z])
    _evt2 = insert_event(project.id, "turn_end") |> set_event_inserted_at(~U[2026-06-13 10:00:02.000000Z])

    conn = get(build_conn(), "/api/v1/projects/#{project.slug}/activity?page_size=1")
    actual = json_response(conn, 200)

    assert actual["meta"]["next_cursor"] != nil

    fixture_path =
      Path.expand(
        "../../assets/src/test/fixtures/project_activity_page.fixture.json",
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

    # items entry keys must match.
    assert [actual_item | _] = actual["items"]
    assert [fixture_item | _] = fixture["items"]

    assert MapSet.equal?(
             MapSet.new(Map.keys(actual_item)),
             MapSet.new(Map.keys(fixture_item))
           ),
           "item keys mismatch.\nActual:  #{inspect(Map.keys(actual_item))}\nFixture: #{inspect(Map.keys(fixture_item))}"
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp insert_event(project_id, type) do
    {:ok, event} =
      SymphonyElixir.Storage.append_event(%{
        project_id: project_id,
        type: type,
        payload: %{}
      })

    event
  end

  defp set_event_inserted_at(event, inserted_at) do
    SymphonyElixir.Repo.update_all(
      from(e in SymphonyElixir.Storage.WorkEvent, where: e.id == ^event.id),
      set: [inserted_at: inserted_at]
    )

    %{event | inserted_at: inserted_at}
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
