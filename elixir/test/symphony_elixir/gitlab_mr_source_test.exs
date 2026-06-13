defmodule SymphonyElixir.WorkSources.GitlabMrSourceTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.WorkSources.GitlabMrSource
  alias SymphonyElixir.Gitlab.MergeRequest

  test "fetch_candidates emits a gitlab_mr_observed run per MR" do
    project = %{id: 1, slug: "demo", forge_type: "gitlab", forge_owner: "group", forge_repo: "api", linear_team_key: "ABC"}
    mr = %MergeRequest{number: 5, title: "Fix ABC-1", body: "ABC-1", head_sha: "abc", head_ref: "f", base_ref: "main"}

    opts = [
      list_merge_requests: fn "group", "api", _ -> {:ok, [mr]} end,
      persist_link: fn _attrs -> :ok end
    ]

    assert {:ok, [run]} = GitlabMrSource.fetch_candidates(project, opts)
    assert run.type == "gitlab_mr_observed"
    assert run.forge_pr_number == 5
    assert run.linear_identifier == "ABC-1"
  end
end
