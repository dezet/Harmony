defmodule SymphonyElixir.ForgePickerApiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.Forge

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    start_test_endpoint()
    Forge.Memory.reset()
    :ok
  end

  defp post_json(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  test "lists repositories for a forge with a token" do
    Forge.Memory.seed_repositories([
      %{owner: "dezet", name: "portal", default_branch: "main", url: "https://x/portal"}
    ])

    conn = post_json("/api/v1/forge/repositories", %{forge_type: "memory", token: "tok"})

    assert %{"repositories" => [repo], "truncated" => false} = json_response(conn, 200)

    assert repo == %{
             "owner" => "dezet",
             "name" => "portal",
             "default_branch" => "main",
             "url" => "https://x/portal"
           }
  end

  test "422 when no token and no env fallback" do
    System.delete_env("GITHUB_TOKEN")
    System.delete_env("GH_TOKEN")

    conn = post_json("/api/v1/forge/repositories", %{forge_type: "github", token: ""})

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
