defmodule SymphonyElixir.ArtifactApiTest do
  @moduledoc """
  Integration tests for GET /api/v1/artifacts/:id.

  Security-critical tests are included:
  - unknown/garbage UUID → 404
  - artifact row whose path is outside the workspace root (bypasses manifest
    validation by inserting directly) → 403
  - prefix-bypass: a sibling dir whose name starts with the root string → 403
  - valid file under workspace root → 200 with correct bytes + headers
  - file deleted from disk after row insert → 404
  - non-GET → 405
  """

  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]

  @endpoint SymphonyElixirWeb.Endpoint

  # ---------------------------------------------------------------------------
  # DB + temp workspace setup
  # ---------------------------------------------------------------------------

  setup do
    start_test_endpoint()
    :ok
  end

  setup :checkout_repo

  setup do
    # Create a temporary workspace root for this test and point Config at it.
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "harmony-artifact-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace_root)

    # Write the workflow file so Config.settings!().workspace.root resolves to
    # our temp dir — same mechanism used by workspace_and_config_test.exs.
    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      workspace_root: workspace_root
    )

    # Create a project + work run to satisfy the artifact FK constraints.
    {:ok, project} =
      SymphonyElixir.Storage.upsert_project(%{
        slug: "artifact-api-proj-#{System.unique_integer([:positive])}",
        linear_project_slug: "art-linear",
        github_owner: "acme",
        github_repo: "app",
        github_base_branch: "main",
        linear_human_review_state: "Human Review",
        config_version: 1,
        config: %{}
      })

    {:ok, run} =
      SymphonyElixir.Storage.create_work_run(%{
        project_id: project.id,
        type: "implementation",
        status: "done",
        agent_backend: "codex",
        payload: %{}
      })

    on_exit(fn -> File.rm_rf(workspace_root) end)

    %{workspace_root: workspace_root, project: project, run: run}
  end

  # ---------------------------------------------------------------------------
  # 404 — unknown UUID and garbage id
  # ---------------------------------------------------------------------------

  @tag :db
  test "returns 404 for an unknown valid UUID" do
    unknown = Ecto.UUID.generate()
    conn = get(build_conn(), "/api/v1/artifacts/#{unknown}")
    assert json_response(conn, 404)["error"]["code"] == "artifact_not_found"
  end

  @tag :db
  test "returns 404 for a garbage (non-UUID) id" do
    for garbage <- ["not-a-uuid", "123", "deadbeef-notauuid"] do
      conn = get(build_conn(), "/api/v1/artifacts/#{garbage}")
      assert json_response(conn, 404)["error"]["code"] == "artifact_not_found",
             "expected 404 for garbage id=#{inspect(garbage)}"
    end
  end

  # ---------------------------------------------------------------------------
  # 403 — path-escape: artifact row points outside workspace root
  # ---------------------------------------------------------------------------

  @tag :db
  test "returns 403 when artifact path is outside workspace root", %{
    project: project,
    run: run
  } do
    # Insert directly — this bypasses manifest.ex validation intentionally.
    {:ok, artifact} =
      SymphonyElixir.Storage.create_artifact(%{
        project_id: project.id,
        work_run_id: run.id,
        kind: "screenshot",
        path: "/etc/passwd",
        metadata: %{}
      })

    conn = get(build_conn(), "/api/v1/artifacts/#{artifact.id}")
    assert json_response(conn, 403)["error"]["code"] == "artifact_path_unsafe"
  end

  # ---------------------------------------------------------------------------
  # 403 — prefix-bypass: root = /tmp/foo, path = /tmp/foo-evil/file.txt
  # ---------------------------------------------------------------------------

  @tag :db
  test "returns 403 for prefix-bypass path (sibling dir starting with root string)", %{
    workspace_root: workspace_root,
    project: project,
    run: run
  } do
    # Craft a path in a sibling dir whose name shares the root prefix.
    evil_dir = workspace_root <> "-evil"
    File.mkdir_p!(evil_dir)
    evil_file = Path.join(evil_dir, "payload.txt")
    File.write!(evil_file, "should not be served")

    {:ok, artifact} =
      SymphonyElixir.Storage.create_artifact(%{
        project_id: project.id,
        work_run_id: run.id,
        kind: "report",
        path: evil_file,
        metadata: %{}
      })

    conn = get(build_conn(), "/api/v1/artifacts/#{artifact.id}")
    assert json_response(conn, 403)["error"]["code"] == "artifact_path_unsafe"

    File.rm_rf(evil_dir)
  end

  # ---------------------------------------------------------------------------
  # 200 — screenshot (png) → image/png, inline
  # ---------------------------------------------------------------------------

  @tag :db
  test "returns 200 with file bytes, image/png content-type, inline disposition for a screenshot png",
       %{workspace_root: workspace_root, project: project, run: run} do
    png_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0>>
    file_path = Path.join(workspace_root, "shot.png")
    File.write!(file_path, png_bytes)

    {:ok, artifact} =
      SymphonyElixir.Storage.create_artifact(%{
        project_id: project.id,
        work_run_id: run.id,
        kind: "screenshot",
        path: file_path,
        metadata: %{}
      })

    conn = get(build_conn(), "/api/v1/artifacts/#{artifact.id}")
    assert conn.status == 200
    assert conn.resp_body == png_bytes
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
    assert get_resp_header(conn, "content-disposition") |> hd() == "inline"
  end

  # ---------------------------------------------------------------------------
  # 200 — video → video/mp4, attachment
  # ---------------------------------------------------------------------------

  @tag :db
  test "returns 200 with video/mp4 content-type and attachment disposition for a video",
       %{workspace_root: workspace_root, project: project, run: run} do
    mp4_bytes = "fake-mp4-content"
    file_path = Path.join(workspace_root, "run.mp4")
    File.write!(file_path, mp4_bytes)

    {:ok, artifact} =
      SymphonyElixir.Storage.create_artifact(%{
        project_id: project.id,
        work_run_id: run.id,
        kind: "video",
        path: file_path,
        metadata: %{}
      })

    conn = get(build_conn(), "/api/v1/artifacts/#{artifact.id}")
    assert conn.status == 200
    assert conn.resp_body == mp4_bytes
    assert get_resp_header(conn, "content-type") |> hd() =~ "video/mp4"

    [disposition] = get_resp_header(conn, "content-disposition")
    assert String.starts_with?(disposition, "attachment")
    assert disposition =~ "run.mp4"
  end

  # ---------------------------------------------------------------------------
  # 200 — screenshot with unknown extension → application/octet-stream, attachment
  # ---------------------------------------------------------------------------

  @tag :db
  test "returns application/octet-stream attachment for screenshot with unknown extension",
       %{workspace_root: workspace_root, project: project, run: run} do
    file_path = Path.join(workspace_root, "shot.bmp")
    File.write!(file_path, "bmp-data")

    {:ok, artifact} =
      SymphonyElixir.Storage.create_artifact(%{
        project_id: project.id,
        work_run_id: run.id,
        kind: "screenshot",
        path: file_path,
        metadata: %{}
      })

    conn = get(build_conn(), "/api/v1/artifacts/#{artifact.id}")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/octet-stream"

    [disposition] = get_resp_header(conn, "content-disposition")
    assert String.starts_with?(disposition, "attachment")
  end

  # ---------------------------------------------------------------------------
  # 404 — file deleted from disk after row insert
  # ---------------------------------------------------------------------------

  @tag :db
  test "returns 404 when the file has been deleted from disk after insert",
       %{workspace_root: workspace_root, project: project, run: run} do
    file_path = Path.join(workspace_root, "gone.png")
    File.write!(file_path, "content")

    {:ok, artifact} =
      SymphonyElixir.Storage.create_artifact(%{
        project_id: project.id,
        work_run_id: run.id,
        kind: "screenshot",
        path: file_path,
        metadata: %{}
      })

    File.rm!(file_path)

    conn = get(build_conn(), "/api/v1/artifacts/#{artifact.id}")
    assert json_response(conn, 404)["error"]["code"] == "artifact_not_found"
  end

  # ---------------------------------------------------------------------------
  # 405 — non-GET methods
  # ---------------------------------------------------------------------------

  @tag :db
  test "returns 405 for non-GET methods" do
    fake_id = Ecto.UUID.generate()

    for method <- [:post, :put, :patch, :delete] do
      conn = method |> build_conn("/api/v1/artifacts/#{fake_id}") |> dispatch_method(method)
      assert json_response(conn, 405)["error"]["code"] == "method_not_allowed",
             "expected 405 for #{method}"
    end
  end

  # ---------------------------------------------------------------------------
  # Unit test for path_within?/2 — prefix-bypass in isolation
  # ---------------------------------------------------------------------------

  test "path_within?/2 returns false for a sibling dir whose name starts with root" do
    root = "/tmp/workspaces"
    evil = "/tmp/workspaces-evil/file.txt"
    refute SymphonyElixirWeb.ArtifactController.path_within?(evil, root)
  end

  test "path_within?/2 returns true for a file directly under root" do
    root = "/tmp/workspaces"
    assert SymphonyElixirWeb.ArtifactController.path_within?("/tmp/workspaces/foo.png", root)
  end

  test "path_within?/2 returns true for a file in a subdirectory of root" do
    root = "/tmp/workspaces"
    assert SymphonyElixirWeb.ArtifactController.path_within?("/tmp/workspaces/sub/dir/f.txt", root)
  end

  test "path_within?/2 returns false for a completely unrelated path" do
    root = "/tmp/workspaces"
    refute SymphonyElixirWeb.ArtifactController.path_within?("/etc/passwd", root)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp dispatch_method(conn, :post), do: post(conn, conn.request_path)
  defp dispatch_method(conn, :put), do: put(conn, conn.request_path)
  defp dispatch_method(conn, :patch), do: patch(conn, conn.request_path)
  defp dispatch_method(conn, :delete), do: delete(conn, conn.request_path)
end
