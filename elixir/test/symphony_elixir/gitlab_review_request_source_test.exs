defmodule SymphonyElixir.WorkSources.GitlabReviewRequestSourceTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.WorkSources.GitlabReviewRequestSource
  alias SymphonyElixir.Gitlab.{MergeRequest, Note}

  test "fetch_candidates emits a code_review run when a note contains the trigger" do
    project = %{id: 1, slug: "demo", forge_type: "gitlab", forge_owner: "group", forge_repo: "api"}
    mr = %MergeRequest{number: 5, head_sha: "abc", head_ref: "f", base_ref: "main"}
    note = %Note{id: 11, body: "please @hreview", author: "dev"}

    opts = [
      list_merge_requests: fn "group", "api", _ -> {:ok, [mr]} end,
      list_notes: fn "group", "api", 5, _ -> {:ok, [note]} end,
      dedupe_seen?: fn _project_id, _key -> false end
    ]

    assert {:ok, [run]} = GitlabReviewRequestSource.fetch_candidates(project, opts)
    assert run.type == "code_review"
    assert run.dedupe_key == "gitlab-review:group/api:5:11:abc:1"
    assert run.payload.trigger_comment_id == 11
  end
end
