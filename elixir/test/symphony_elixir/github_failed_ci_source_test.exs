defmodule SymphonyElixir.GithubFailedCiSourceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Github.{PullRequest, WorkflowRun}
  alias SymphonyElixir.WorkSources.GithubFailedCiSource

  test "emits ci_fix work run for failed github actions run" do
    project = %{
      id: "project-1",
      slug: "portal",
      github_owner: "dezet",
      github_repo: "portal",
      github_base_branch: "develop",
      linear_team_key: "COD",
      config: %{}
    }

    pull_requests = fn _owner, _repo, _opts ->
      {:ok,
       [
         %PullRequest{
           number: 7,
           title: "Fix COD-5",
           body: "Linear: COD-5",
           head_sha: "abc123",
           head_ref: "fix-cod-5",
           head_repo_full_name: "dezet/portal",
           base_ref: "develop",
           base_repo_full_name: "dezet/portal"
         }
       ]}
    end

    workflow_runs = fn _owner, _repo, opts ->
      assert opts[:head_sha] == "abc123"
      {:ok, [%WorkflowRun{id: 123, name: "CI", head_sha: "abc123", status: "completed", conclusion: "failure"}]}
    end

    assert {:ok, [run]} =
             GithubFailedCiSource.fetch_candidates(project,
               list_pull_requests: pull_requests,
               list_workflow_runs: workflow_runs,
               dedupe_seen?: fn _project_id, _key -> false end
             )

    assert run.type == "ci_fix"
    assert run.dedupe_key == "github-ci-fix:dezet/portal:7:abc123:123"
    assert run.github_pr_number == 7
  end

  test "skips failed run when dedupe key is already processed" do
    project = %{
      id: "project-1",
      slug: "portal",
      github_owner: "dezet",
      github_repo: "portal",
      github_base_branch: "develop",
      linear_team_key: "COD",
      config: %{}
    }

    pull_requests = fn _owner, _repo, _opts ->
      {:ok,
       [
         %PullRequest{
           number: 7,
           head_sha: "abc123",
           head_ref: "fix",
           head_repo_full_name: "dezet/portal",
           base_ref: "develop",
           base_repo_full_name: "dezet/portal"
         }
       ]}
    end

    workflow_runs = fn _owner, _repo, _opts ->
      {:ok, [%WorkflowRun{id: 123, name: "CI", head_sha: "abc123", status: "completed", conclusion: "failure"}]}
    end

    assert {:ok, []} =
             GithubFailedCiSource.fetch_candidates(project,
               list_pull_requests: pull_requests,
               list_workflow_runs: workflow_runs,
               dedupe_seen?: fn _project_id, _key -> true end
             )
  end
end
