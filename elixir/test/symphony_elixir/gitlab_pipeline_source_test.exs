defmodule SymphonyElixir.WorkSources.GitlabPipelineSourceTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.WorkSources.GitlabPipelineSource
  alias SymphonyElixir.Gitlab.{MergeRequest, Pipeline}

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
