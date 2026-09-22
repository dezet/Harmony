defmodule SymphonyElixir.ReviewResponseSourceTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.WorkRun
  alias SymphonyElixir.WorkSources.{GithubReviewResponseSource, GitlabReviewResponseSource}

  @project %{
    id: "proj-1",
    slug: "portal",
    forge_type: "github",
    forge_owner: "dezet",
    forge_repo: "portal",
    linear_team_key: "COD",
    config: %{}
  }

  @gitlab_project %{
    id: "proj-gl-1",
    slug: "portal",
    forge_type: "gitlab",
    forge_owner: "dezet",
    forge_repo: "portal",
    forge_secret: "test-token",
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
      dedupe_status: fn _project_id, _key -> nil end,
      attempt_count: fn _project_id, _key -> 0 end
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
      dedupe_status: fn _project_id, _key -> nil end,
      harmony_identity: "harmony[bot]"
    ]

    assert {:ok, []} = GithubReviewResponseSource.fetch_candidates(@project, opts)
  end

  test "GitLab emits an address_review run for an unresolved reviewer thread" do
    opts = [
      list_pull_requests: fn "dezet", "portal", [] -> {:ok, [@pr]} end,
      list_review_threads: fn "dezet", "portal", 7 -> {:ok, [@thread]} end,
      dedupe_status: fn "proj-gl-1", _key -> nil end,
      attempt_count: fn "proj-gl-1", _key -> 0 end,
      harmony_identity: "harmony[bot]"
    ]

    assert {:ok, [%WorkRun{} = run]} = GitlabReviewResponseSource.fetch_candidates(@gitlab_project, opts)
    assert run.type == "address_review"
    assert run.forge_type == "gitlab"
    assert run.forge_pr_number == 7
    assert run.linear_identifier == "COD-1"
    assert [%{id: "T1"}] = run.payload["threads"]
  end

  test "GitLab skips own replies, processed threads, and threads at the retry cap" do
    own = put_in(@thread.comments, [%{id: "C2", author: "harmony[bot]", body: "done", created_at: "2026-06-14T11:00:00Z"}])

    own_opts = [
      list_pull_requests: fn _owner, _repo, _filters -> {:ok, [@pr]} end,
      list_review_threads: fn _owner, _repo, _number -> {:ok, [own]} end,
      dedupe_status: fn _project_id, _key -> flunk("own replies are filtered before dedupe") end,
      attempt_count: fn _project_id, _key -> flunk("own replies are filtered before attempt lookup") end,
      harmony_identity: "harmony[bot]"
    ]

    assert {:ok, []} = GitlabReviewResponseSource.fetch_candidates(@gitlab_project, own_opts)

    for {dedupe_result, attempts} <- [{"processed", 0}, {"claimed", 3}] do
      opts = [
        list_pull_requests: fn _owner, _repo, _filters -> {:ok, [@pr]} end,
        list_review_threads: fn _owner, _repo, _number -> {:ok, [@thread]} end,
        dedupe_status: fn "proj-gl-1", "review-response:dezet/portal:7:T1:C1" -> dedupe_result end,
        attempt_count: fn "proj-gl-1", "review-response:dezet/portal:7:T1:C1" -> attempts end,
        harmony_identity: "harmony[bot]"
      ]

      assert {:ok, []} = GitlabReviewResponseSource.fetch_candidates(@gitlab_project, opts)
    end
  end

  test "GitLab propagates failures while listing review threads" do
    opts = [
      list_pull_requests: fn _owner, _repo, _filters -> {:ok, [@pr]} end,
      list_review_threads: fn _owner, _repo, _number -> {:error, :discussion_service_unavailable} end,
      harmony_identity: "harmony[bot]"
    ]

    assert {:error, :discussion_service_unavailable} =
             GitlabReviewResponseSource.fetch_candidates(@gitlab_project, opts)
  end
end
