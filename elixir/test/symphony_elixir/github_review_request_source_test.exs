defmodule SymphonyElixir.GithubReviewRequestSourceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Github.{Comment, PullRequest}
  alias SymphonyElixir.WorkSources.GithubReviewRequestSource

  test "emits code review work for trigger comment" do
    project = %{
      id: "project-1",
      slug: "portal",
      forge_owner: "dezet",
      forge_repo: "portal",
      forge_base_branch: "develop",
      linear_team_key: "COD",
      config: %{"review" => %{"trigger" => "@hreview", "template_version" => 1}}
    }

    list_prs = fn _owner, _repo, _opts ->
      {:ok,
       [
         %PullRequest{
           number: 7,
           title: "Review COD-5",
           body: "COD-5",
           head_sha: "abc123",
           head_ref: "feature",
           base_ref: "develop",
           head_repo_full_name: "dezet/portal",
           base_repo_full_name: "dezet/portal"
         }
       ]}
    end

    list_comments = fn _owner, _repo, 7, _opts ->
      {:ok, [%Comment{id: 99, body: "@hreview", author: "alice"}]}
    end

    assert {:ok, [run]} =
             GithubReviewRequestSource.fetch_candidates(project,
               list_pull_requests: list_prs,
               list_issue_comments: list_comments,
               dedupe_seen?: fn _project_id, _key -> false end
             )

    assert run.type == "code_review"
    assert run.dedupe_key == "github-review:dezet/portal:7:99:abc123:1"
    assert run.forge_pr_number == 7
  end
end
