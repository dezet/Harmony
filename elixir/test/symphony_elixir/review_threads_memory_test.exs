defmodule SymphonyElixir.ReviewThreadsMemoryTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Forge.Memory

  setup do
    Memory.reset()
    :ok
  end

  test "seed + list_review_threads round-trips the normalized shape" do
    thread = %{
      id: "t1",
      path: "lib/a.ex",
      line: 12,
      resolved: false,
      author: "alice",
      comments: [%{id: "c1", author: "alice", body: "rename this", created_at: ~U[2026-06-14 10:00:00Z]}],
      last_comment_at: ~U[2026-06-14 10:00:00Z]
    }

    Memory.seed_review_threads([thread])
    assert {:ok, [^thread]} = Memory.list_review_threads(%{}, %{owner: "o", repo: "r"}, 7)
  end

  test "reply and resolve are recorded" do
    :ok = Memory.reply_to_review_thread(%{}, %{owner: "o", repo: "r"}, 7, "t1", "fixed")
    :ok = Memory.resolve_review_thread(%{}, %{owner: "o", repo: "r"}, 7, "t1")

    calls = Memory.recorded_calls()
    assert {:reply_to_review_thread, [%{}, %{owner: "o", repo: "r"}, 7, "t1", "fixed"]} in calls
    assert {:resolve_review_thread, [%{}, %{owner: "o", repo: "r"}, 7, "t1"]} in calls
  end
end
