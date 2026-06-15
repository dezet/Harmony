defmodule SymphonyElixir.ReviewRetryLoopTest do
  @moduledoc """
  End-to-end retry loop crossing the handoff -> source boundary.

  Earlier unit tests drove `AddressReviewHandoff.publish/3` directly in a loop,
  which bypassed the source's per-thread reject gate. That hid a correctness bug:
  the source gated on row *existence* (`dedupe_seen?`), so the "claimed" row that
  `increment_review_attempt/2` writes on attempt 1 made the source drop the still
  open thread on every later poll — attempts 2 and 3 never ran. These tests run
  the real source with real Storage seams against the DB and assert the thread is
  re-selected until the cap, then becomes terminal (`processed`).
  """
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Storage, WorkRun}
  alias SymphonyElixir.Workflows.AddressReviewHandoff
  alias SymphonyElixir.WorkSources.GithubReviewResponseSource

  # Agent claims resolved but does NOT change the file -> thread stays open, attempt increments.
  @unaddressed ~s({"threads":[{"thread_id":"T1","reply":"hmm","resolved":true}],"files_changed":[]})

  @pr %{
    number: 7,
    head_sha: "abc",
    head_ref: "feature",
    base_ref: "main",
    title: "COD-1 thing",
    body: "",
    url: "https://github.com/o/r/pull/7"
  }

  defp thread(id, comment_id) do
    %{
      id: id,
      path: "lib/#{id}.ex",
      line: 12,
      resolved: false,
      author: "alice",
      comments: [%{id: comment_id, author: "alice", body: "rename", created_at: "2026-06-14T10:00:00Z"}],
      last_comment_at: "2026-06-14T10:00:00Z"
    }
  end

  defp insert_project! do
    {:ok, project} =
      Storage.upsert_project(%{
        "slug" => "retry-loop-#{System.unique_integer([:positive])}",
        "forge_type" => "github",
        "forge_owner" => "o",
        "forge_repo" => "r",
        "forge_base_branch" => "main",
        "linear_team_key" => "COD",
        "config_version" => 1,
        "config" => %{}
      })

    project
  end

  # Run the real source with real Storage gating (only the forge listing is stubbed).
  defp source_opts(threads) do
    [
      harmony_identity: "harmony[bot]",
      list_pull_requests: fn _o, _r, _ -> {:ok, [@pr]} end,
      list_review_threads: fn _o, _r, _n -> {:ok, threads} end
    ]
  end

  @tag :db
  test "an unaddressed thread is re-selected across attempts until the cap, then becomes terminal" do
    :ok = checkout_repo(%{})
    project = insert_project!()
    threads = [thread("T1", "C1")]
    test_pid = self()

    handoff_opts = [
      reply: fn _ref, _c, _t, b ->
        send(test_pid, {:reply, b})
        :ok
      end,
      resolve: fn _r, _c, _t -> :ok end
    ]

    key = "review-response:o/r:7:T1:C1"

    # Attempts 1, 2, 3: each poll must re-select the still-open thread. The bug was
    # that the source dropped the thread after attempt 1's "claimed" row appeared.
    for attempt <- 1..3 do
      assert {:ok, [%WorkRun{} = run]} =
               GithubReviewResponseSource.fetch_candidates(project, source_opts(threads)),
             "expected the source to re-select the open thread on attempt #{attempt}"

      assert :ok = AddressReviewHandoff.publish(run, @unaddressed, handoff_opts)

      if attempt < 3 do
        # Mid-loop the key carries the running attempt count and is NOT yet terminal.
        assert Storage.review_attempt_count(project.id, key) == attempt
        assert Storage.dedupe_status(project.id, key) == "claimed"
      end
    end

    # On the 3rd attempt the key becomes terminal (processed); the source must then
    # stop selecting it regardless of the attempt count.
    assert Storage.dedupe_status(project.id, key) == "processed"

    # The needs-human note fired on the 3rd attempt.
    assert drain_until_needs_human()

    # Now that the key is processed, the source no longer selects the thread.
    assert {:ok, []} = GithubReviewResponseSource.fetch_candidates(project, source_opts(threads))
  end

  @tag :db
  test "two unaddressed threads on one PR track attempt counts independently" do
    :ok = checkout_repo(%{})
    project = insert_project!()
    t1 = thread("T1", "C1")
    t2 = thread("T2", "C2")

    handoff_opts = [reply: fn _ref, _c, _t, _b -> :ok end, resolve: fn _r, _c, _t -> :ok end]

    # First poll: both threads selected. Advance ONLY T1 by publishing a decision
    # that touches T1 alone.
    assert {:ok, [%WorkRun{} = run]} =
             GithubReviewResponseSource.fetch_candidates(project, source_opts([t1, t2]))

    only_t1 = ~s({"threads":[{"thread_id":"T1","reply":"hmm","resolved":true}],"files_changed":[]})
    assert :ok = AddressReviewHandoff.publish(run, only_t1, handoff_opts)

    key1 = "review-response:o/r:7:T1:C1"
    key2 = "review-response:o/r:7:T2:C2"

    assert Storage.review_attempt_count(project.id, key1) == 1
    assert Storage.review_attempt_count(project.id, key2) == 0

    # Next poll: both threads still selected (T1 not yet capped, T2 untouched).
    assert {:ok, [%WorkRun{} = run2]} =
             GithubReviewResponseSource.fetch_candidates(project, source_opts([t1, t2]))

    selected_ids =
      (run2.payload["threads"] || run2.payload[:threads])
      |> Enum.map(& &1.id)
      |> Enum.sort()

    assert selected_ids == ["T1", "T2"]
  end

  defp drain_until_needs_human do
    receive do
      {:reply, body} ->
        String.contains?(body, "needs human review") or drain_until_needs_human()
    after
      0 -> false
    end
  end
end
