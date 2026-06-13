defmodule SymphonyElixir.GithubFailedCiSourceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Github.{PullRequest, WorkflowRun}
  alias SymphonyElixir.WorkSources.GithubFailedCiSource

  test "emits ci_fix work run for failed github actions run" do
    project = %{
      id: "project-1",
      slug: "portal",
      forge_owner: "dezet",
      forge_repo: "portal",
      forge_base_branch: "develop",
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

      {:ok,
       [
         %WorkflowRun{
           id: 123,
           name: "CI",
           head_sha: "abc123",
           status: "completed",
           conclusion: "failure",
           url: "https://github.com/dezet/portal/actions/runs/123"
         }
       ]}
    end

    logs = fn "dezet", "portal", 123, [] -> {:ok, "mix test failed\nstacktrace"} end

    assert {:ok, [run]} =
             GithubFailedCiSource.fetch_candidates(project,
               list_pull_requests: pull_requests,
               list_workflow_runs: workflow_runs,
               get_workflow_run_logs: logs,
               dedupe_seen?: fn _project_id, _key -> false end
             )

    assert run.type == "ci_fix"
    assert run.dedupe_key == "github-ci-fix:dezet/portal:7:abc123:123"
    assert run.forge_pr_number == 7
    assert run.payload.workflow_run.url == "https://github.com/dezet/portal/actions/runs/123"
    assert run.payload.log_excerpt == "mix test failed\nstacktrace"
  end

  test "records log fetch errors without crashing failed ci polling" do
    project = %{
      id: "project-1",
      slug: "portal",
      forge_owner: "dezet",
      forge_repo: "portal",
      forge_base_branch: "develop",
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

    workflow_runs = fn _owner, _repo, _opts ->
      {:ok, [%WorkflowRun{id: 123, name: "CI", head_sha: "abc123", status: "completed", conclusion: "failure"}]}
    end

    logs = fn _owner, _repo, _run_id, _opts -> {:error, :not_found} end

    assert {:ok, [run]} =
             GithubFailedCiSource.fetch_candidates(project,
               list_pull_requests: pull_requests,
               list_workflow_runs: workflow_runs,
               get_workflow_run_logs: logs,
               dedupe_seen?: fn _project_id, _key -> false end
             )

    assert run.payload.log_fetch_error == ":not_found"
    refute Map.has_key?(run.payload, :log_excerpt)
  end

  test "skips failed run when dedupe key is already processed" do
    project = %{
      id: "project-1",
      slug: "portal",
      forge_owner: "dezet",
      forge_repo: "portal",
      forge_base_branch: "develop",
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

  test "marks fork PR as repair branch required" do
    project = %{
      id: "project-1",
      slug: "portal",
      forge_owner: "dezet",
      forge_repo: "portal",
      forge_base_branch: "develop",
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
           head_repo_full_name: "fork/portal",
           base_ref: "develop",
           base_repo_full_name: "dezet/portal"
         }
       ]}
    end

    workflow_runs = fn _owner, _repo, _opts ->
      {:ok, [%WorkflowRun{id: 123, name: "CI", head_sha: "abc123", status: "completed", conclusion: "failure"}]}
    end

    assert {:ok, [run]} =
             GithubFailedCiSource.fetch_candidates(project,
               list_pull_requests: pull_requests,
               list_workflow_runs: workflow_runs,
               dedupe_seen?: fn _project_id, _key -> false end
             )

    assert run.payload.repo_policy == "repair_branch_required"
  end
end
