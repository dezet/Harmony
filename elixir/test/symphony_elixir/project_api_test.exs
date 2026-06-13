defmodule SymphonyElixir.ProjectApiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    start_test_endpoint()
    :ok
  end

  @valid %{
    "slug" => "portal",
    "linear_project_slug" => "portal-linear",
    "linear_team_key" => "COD",
    "linear_human_review_state" => "Human Review",
    "github_owner" => "dezet",
    "github_repo" => "portal",
    "github_base_branch" => "main",
    "config_version" => 1,
    "config" => %{"review" => %{"trigger" => "@hreview"}}
  }

  defp json_post(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp json_put(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put(path, Jason.encode!(body))
  end

  @tag :db
  test "creates a project and lists it" do
    :ok = checkout_repo(%{})

    conn = json_post("/api/v1/projects", @valid)

    assert %{"project" => %{"id" => id, "slug" => "portal", "github_repo" => "portal"}} =
             json_response(conn, 201)

    assert is_binary(id)

    list = get(build_conn(), "/api/v1/projects")
    assert %{"projects" => [%{"slug" => "portal"}]} = json_response(list, 200)
  end

  @tag :db
  test "returns 422 with field errors for an invalid project" do
    :ok = checkout_repo(%{})

    conn = json_post("/api/v1/projects", Map.delete(@valid, "slug"))
    body = json_response(conn, 422)
    assert body["error"]["code"] == "validation_failed"
    assert is_list(body["error"]["fields"]["slug"])
  end

  @tag :db
  test "updates an existing project" do
    :ok = checkout_repo(%{})
    {:ok, project} =
      SymphonyElixir.Storage.upsert_project(%{
        slug: "portal",
        linear_project_slug: "portal-linear",
        linear_team_key: "COD",
        linear_human_review_state: "Human Review",
        forge_owner: "dezet",
        forge_repo: "portal",
        forge_base_branch: "main",
        config_version: 1,
        config: %{"review" => %{"trigger" => "@hreview"}}
      })

    conn = json_put("/api/v1/projects/#{project.id}", Map.put(@valid, "github_base_branch", "develop"))
    assert %{"project" => %{"github_base_branch" => "develop"}} = json_response(conn, 200)
  end

  @tag :db
  test "returns 404 for an unknown project id" do
    :ok = checkout_repo(%{})
    conn = get(build_conn(), "/api/v1/projects/00000000-0000-0000-0000-000000000000")
    assert json_response(conn, 404)["error"]["code"] == "not_found"
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
