defmodule SymphonyElixir.GithubWorkSourceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Github.PullRequest
  alias SymphonyElixir.WorkSources.GithubPrSource

  test "maps open PR candidates and resolved linear links" do
    parent = self()

    project = %{
      id: "project-1",
      slug: "portal",
      github_owner: "dezet",
      github_repo: "portal",
      github_base_branch: "develop",
      linear_team_key: "COD"
    }

    list_prs = fn _owner, _repo, _opts ->
      {:ok,
       [
         %PullRequest{
           number: 7,
           title: "Fix COD-5",
           body: "Linear: https://linear.app/dezet/issue/COD-5/smoke-test",
           head_sha: "abc123",
           head_ref: "fix-cod-5",
           head_repo_full_name: "dezet/portal",
           base_ref: "develop",
           base_repo_full_name: "dezet/portal"
         }
       ]}
    end

    persist_link = fn attrs ->
      send(parent, {:persist_link, attrs})
      {:ok, attrs}
    end

    assert {:ok, [candidate]} =
             GithubPrSource.fetch_candidates(project,
               list_pull_requests: list_prs,
               persist_link: persist_link
             )

    assert candidate.github_pr_number == 7
    assert candidate.linear_identifier == "COD-5"

    assert_received {:persist_link,
                     %{
                       github_pr_number: 7,
                       github_head_sha: "abc123",
                       github_head_ref: "fix-cod-5",
                       github_base_ref: "develop",
                       linear_identifier: "COD-5"
                     }}
  end

  @tag :db
  test "records open PR candidates and resolved linear links" do
    :ok = checkout_repo(%{})

    {:ok, project} =
      SymphonyElixir.Storage.upsert_project(%{
        slug: "portal",
        github_owner: "dezet",
        github_repo: "portal",
        github_base_branch: "develop",
        linear_project_slug: "portal-linear",
        linear_team_key: "COD",
        linear_human_review_state: "Human Review",
        config_version: 1,
        config: %{}
      })

    list_prs = fn _owner, _repo, _opts ->
      {:ok,
       [
         %PullRequest{
           number: 7,
           title: "Fix COD-5",
           body: "Linear: https://linear.app/dezet/issue/COD-5/smoke-test",
           head_sha: "abc123",
           head_ref: "fix-cod-5",
           head_repo_full_name: "dezet/portal",
           base_ref: "develop",
           base_repo_full_name: "dezet/portal"
         }
       ]}
    end

    assert {:ok, [candidate]} = GithubPrSource.fetch_candidates(project, list_pull_requests: list_prs)
    assert candidate.github_pr_number == 7
    assert candidate.linear_identifier == "COD-5"
  end
end
