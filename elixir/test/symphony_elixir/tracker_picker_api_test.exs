defmodule SymphonyElixir.TrackerPickerApiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    start_test_endpoint()
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    prev = Application.get_env(:symphony_elixir, :memory_tracker_projects)
    on_exit(fn -> Application.put_env(:symphony_elixir, :memory_tracker_projects, prev) end)
    :ok
  end

  defp post_json(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  test "lists tracker projects for a token" do
    Application.put_env(:symphony_elixir, :memory_tracker_projects, [
      %{id: "p1", name: "Portal", slug: "portal", team_key: "COD"}
    ])

    conn = post_json("/api/v1/tracker/projects", %{token: "tok"})

    assert %{"projects" => [proj], "truncated" => false} = json_response(conn, 200)

    assert proj == %{"id" => "p1", "name" => "Portal", "slug" => "portal", "team_key" => "COD"}
  end

  test "422 when no token and no env fallback" do
    System.delete_env("LINEAR_API_KEY")
    conn = post_json("/api/v1/tracker/projects", %{token: ""})
    assert json_response(conn, 422)["error"]["code"] == "missing_credentials"
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
