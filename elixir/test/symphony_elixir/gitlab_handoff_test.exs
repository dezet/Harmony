defmodule SymphonyElixir.GitlabHandoffTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflows.{CiFixHandoff, ReviewHandoff}
  alias SymphonyElixir.WorkRun

  setup do
    prev_gitlab = System.get_env("GITLAB_TOKEN")
    prev_github = System.get_env("GITHUB_TOKEN")
    System.put_env("GITLAB_TOKEN", "gl-tok")
    System.put_env("GITHUB_TOKEN", "gh-tok")

    on_exit(fn ->
      restore_env("GITLAB_TOKEN", prev_gitlab)
      restore_env("GITHUB_TOKEN", prev_github)
    end)

    :ok
  end

  defp capturing_request_fun(parent) do
    fn req ->
      send(parent, {:http_request, req[:url], req[:headers]})
      {:ok, %{status: 201, body: %{}}}
    end
  end

  test "a gitlab ci_fix blocker posts an MR note on the GitLab instance with the GitLab token" do
    parent = self()

    run = %WorkRun{
      forge_type: "gitlab",
      forge_base_url: "https://gl.example.com",
      forge_owner: "group",
      forge_repo: "api",
      forge_pr_number: 5,
      payload: %{blocker_reason: "fork PR requires repair branch"}
    }

    assert :ok =
             CiFixHandoff.blocked(run,
               request_fun: capturing_request_fun(parent),
               linear_comment: fn _id, _body -> :ok end,
               linear_state: fn _id, _state -> :ok end
             )

    assert_received {:http_request, url, headers}
    assert url == "https://gl.example.com/api/v4/projects/group%2Fapi/merge_requests/5/notes"
    assert {"private-token", "gl-tok"} in headers
  end

  test "a gitlab @hreview review publishes an MR note on the GitLab instance with the GitLab token" do
    parent = self()

    run = %WorkRun{
      forge_type: "gitlab",
      forge_base_url: "https://gl.example.com",
      forge_owner: "group",
      forge_repo: "api",
      forge_pr_number: 5,
      dedupe_key: "gitlab-review:group/api:5:99:abc:1"
    }

    assert :ok = ReviewHandoff.publish(run, "Review body", request_fun: capturing_request_fun(parent))

    assert_received {:http_request, url, headers}
    assert url == "https://gl.example.com/api/v4/projects/group%2Fapi/merge_requests/5/notes"
    assert {"private-token", "gl-tok"} in headers
  end
end
