defmodule SymphonyElixir.ReviewResponseSourceTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.WorkSources.GithubReviewResponseSource
  alias SymphonyElixir.WorkRun

  @project %{
    id: "proj-1",
    slug: "portal",
    forge_type: "github",
    forge_owner: "dezet",
    forge_repo: "portal",
    linear_team_key: "COD",
    config: %{}
  }

  @pr %{number: 7, head_sha: "abc", head_ref: "feature", base_ref: "main", title: "COD-1 thing", body: "", url: "https://github.com/dezet/portal/pull/7"}

  @thread %{
    id: "T1",
    path: "lib/a.ex",
    line: 12,
    resolved: false,
    author: "alice",
    comments: [%{id: "C1", author: "alice", body: "rename", created_at: "2026-06-14T10:00:00Z"}],
    last_comment_at: "2026-06-14T10:00:00Z"
  }

  test "emits an address_review run for an unresolved reviewer thread" do
    opts = [
      list_pull_requests: fn _o, _r, _ -> {:ok, [@pr]} end,
      list_review_threads: fn _o, _r, _n -> {:ok, [@thread]} end,
      dedupe_seen?: fn _project_id, _key -> false end
    ]

    assert {:ok, [%WorkRun{} = run]} = GithubReviewResponseSource.fetch_candidates(@project, opts)
    assert run.type == "address_review"
    assert run.forge_pr_number == 7
    assert [%{id: "T1"}] = run.payload["threads"] || run.payload[:threads]
  end

  test "skips threads whose newest comment is Harmony's own reply" do
    own = put_in(@thread.comments, [%{id: "C2", author: "harmony[bot]", body: "done", created_at: "2026-06-14T11:00:00Z"}])
    own = Map.put(own, :last_comment_at, "2026-06-14T11:00:00Z")

    opts = [
      list_pull_requests: fn _o, _r, _ -> {:ok, [@pr]} end,
      list_review_threads: fn _o, _r, _n -> {:ok, [own]} end,
      dedupe_seen?: fn _project_id, _key -> false end,
      harmony_identity: "harmony[bot]"
    ]

    assert {:ok, []} = GithubReviewResponseSource.fetch_candidates(@project, opts)
  end
end
