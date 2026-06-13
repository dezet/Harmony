defmodule SymphonyElixir.WorkSources.GitlabPipelineSourceTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.WorkSources.GitlabPipelineSource
  alias SymphonyElixir.Gitlab.{MergeRequest, Pipeline}

  test "blocks push to a protected branch listed in project config but not the base branch" do
    # Scenario: a non-fork MR whose head_ref is "release", which is listed in
    # config.protected_branches but is NOT forge_base_branch ("main").
    # Current buggy code only wraps forge_base_branch, so it misses "release"
    # and wrongly emits "direct_push_allowed".
    # Fixed code reads config.protected_branches and produces
    # "blocked:protected_branch_push_forbidden" (repo_policy.ex line 21-22).
    project = %{
      id: 1,
      slug: "demo",
      forge_type: "gitlab",
      forge_owner: "group",
      forge_repo: "api",
      forge_base_branch: "main",
      config: %{protected_branches: ["main", "release"]}
    }

    mr = %MergeRequest{
      number: 10,
      head_sha: "def",
      head_ref: "release",
      base_ref: "main",
      head_repo_full_name: "group/api",
      base_repo_full_name: "group/api"
    }

    pipeline = %Pipeline{id: 42, status: "failed", sha: "def"}

    opts = [
      list_merge_requests: fn "group", "api", _ -> {:ok, [mr]} end,
      list_pipelines: fn "group", "api", _ -> {:ok, [pipeline]} end,
      get_pipeline_logs: fn "group", "api", 42, _ -> {:ok, "ci error"} end,
      dedupe_seen?: fn _project_id, _key -> false end
    ]

    assert {:ok, [run]} = GitlabPipelineSource.fetch_candidates(project, opts)
    assert run.payload.repo_policy == "blocked:protected_branch_push_forbidden"
  end

  test "fetch_candidates emits a ci_fix run for a failed pipeline with log excerpt" do
    project = %{id: 1, slug: "demo", forge_type: "gitlab", forge_owner: "group", forge_repo: "api", forge_base_branch: "main"}
    mr = %MergeRequest{number: 5, head_sha: "abc", head_ref: "f", base_ref: "main", head_repo_full_name: "7", base_repo_full_name: "7"}
    pipeline = %Pipeline{id: 9, status: "failed", sha: "abc"}

    opts = [
      list_merge_requests: fn "group", "api", _ -> {:ok, [mr]} end,
      list_pipelines: fn "group", "api", _ -> {:ok, [pipeline]} end,
      get_pipeline_logs: fn "group", "api", 9, _ -> {:ok, "boom"} end,
      dedupe_seen?: fn _project_id, _key -> false end
    ]

    assert {:ok, [run]} = GitlabPipelineSource.fetch_candidates(project, opts)
    assert run.type == "ci_fix"
    assert run.dedupe_key == "gitlab-ci-fix:group/api:5:abc:9"
    assert run.payload.log_excerpt == "boom"
    assert run.payload.repo_policy == "direct_push_allowed"
  end
end
