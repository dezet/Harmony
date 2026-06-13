defmodule SymphonyElixir.Forge.ProjectCredsTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Forge.ProjectCreds

  test "creds/2 selects the GitLab token for gitlab projects" do
    System.put_env("GITLAB_TOKEN", "gl-secret")
    on_exit(fn -> System.delete_env("GITLAB_TOKEN") end)

    creds = ProjectCreds.creds(%{forge_type: "gitlab", forge_base_url: "https://gl.example.com"})
    assert creds.token == "gl-secret"
    assert creds.base_url == "https://gl.example.com"
  end

  test "gitlab_client_opts/2 carries base_url and request_fun" do
    fun = fn _ -> {:ok, %{status: 200, body: []}} end
    opts = ProjectCreds.gitlab_client_opts(%{forge_base_url: "https://gl.example.com"}, request_fun: fun)
    assert opts[:base_url] == "https://gl.example.com"
    assert opts[:request_fun] == fun
  end
end
