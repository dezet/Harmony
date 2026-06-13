defmodule SymphonyElixir.LinearListProjectsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Client

  @body %{
    "data" => %{
      "teams" => %{
        "nodes" => [
          %{
            "key" => "COD",
            "projects" => %{
              "nodes" => [
                %{"id" => "p1", "name" => "Portal", "slugId" => "portal"},
                %{"id" => "p2", "name" => "Mobile", "slugId" => "mobile"}
              ]
            }
          }
        ]
      }
    }
  }

  test "list_projects/2 normalizes teams->projects and passes the creds token" do
    test_pid = self()

    request_fun = fn _payload, headers ->
      send(test_pid, {:headers, headers})
      {:ok, %{status: 200, body: @body}}
    end

    assert {:ok, projects} = Client.list_projects(%{token: "tok-123"}, request_fun: request_fun)

    assert projects == [
             %{id: "p1", name: "Portal", slug: "portal", team_key: "COD"},
             %{id: "p2", name: "Mobile", slug: "mobile", team_key: "COD"}
           ]

    assert_received {:headers, headers}
    assert {"Authorization", "tok-123"} in headers
  end
end
