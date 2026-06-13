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

  test "creds/2 prefers a project's forge_secret over env" do
    System.put_env("GITHUB_TOKEN", "env-tok")
    on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

    creds = ProjectCreds.creds(%SymphonyElixir.Storage.Project{forge_type: "github", forge_secret: "proj-tok"})
    assert creds.token == "proj-tok"
  end

  test "creds/2 falls back to env when a project has no secret" do
    System.put_env("GITHUB_TOKEN", "env-tok")
    on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

    creds = ProjectCreds.creds(%SymphonyElixir.Storage.Project{forge_type: "github", forge_secret: nil})
    assert creds.token == "env-tok"
  end

  @tag :db
  test "creds/2 resolves a WorkRun's token by forge owner+repo" do
    :ok = SymphonyElixir.TestSupport.checkout_repo(%{})

    {:ok, project} =
      SymphonyElixir.Storage.upsert_project(%{
        slug: "portal", linear_project_slug: "p", linear_team_key: "COD",
        linear_human_review_state: "Human Review", forge_type: "github",
        forge_owner: "dezet", forge_repo: "portal", forge_base_branch: "main",
        config_version: 1, config: %{}
      })

    {:ok, _} = SymphonyElixir.Storage.update_project_secrets(project, %{"forge_secret" => "run-tok"})

    run = %SymphonyElixir.Storage.WorkRun{forge_owner: "dezet", forge_repo: "portal"}
    assert ProjectCreds.creds(run).token == "run-tok"
  end
end
