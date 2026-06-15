defmodule SymphonyElixir.AddressReviewHandoffTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Workflows.AddressReviewHandoff
  alias SymphonyElixir.WorkRun

  @run %WorkRun{
    type: "address_review",
    forge_owner: "o",
    forge_repo: "r",
    forge_pr_number: 7,
    dedupe_key: "review-response:o/r:7:T1:C1",
    payload: %{"project_id" => "proj-1", "threads" => [%{id: "T1", path: "lib/a.ex"}]}
  }

  @body """
  I addressed the rename.
  {"threads": [{"thread_id": "T1", "reply": "Renamed foo to bar.", "resolved": true}],
   "files_changed": ["lib/a.ex"]}
  """

  @body_guarded """
  done.
  {"threads": [{"thread_id": "T1", "reply": "fixed", "resolved": true},
               {"thread_id": "T2", "reply": "n/a", "resolved": true}],
   "files_changed": ["lib/a.ex"]}
  """

  test "replies to and resolves each thread from the structured output" do
    test_pid = self()

    opts = [
      reply: fn ref, change_id, thread_id, body ->
        send(test_pid, {:reply, ref, change_id, thread_id, body})
        :ok
      end,
      resolve: fn ref, change_id, thread_id ->
        send(test_pid, {:resolve, ref, change_id, thread_id})
        :ok
      end,
      append_event: fn _ -> :ok end,
      mark_dedupe_processed: fn _ -> :ok end
    ]

    assert :ok = AddressReviewHandoff.publish(@run, @body, opts)
    assert_received {:reply, _ref, 7, "T1", "Renamed foo to bar."}
    assert_received {:resolve, _ref, 7, "T1"}
  end

  test "resolves only threads whose path was changed" do
    run = %WorkRun{
      type: "address_review",
      forge_owner: "o",
      forge_repo: "r",
      forge_pr_number: 7,
      dedupe_key: "k",
      payload: %{
        "project_id" => "p1",
        "threads" => [%{id: "T1", path: "lib/a.ex"}, %{id: "T2", path: "lib/b.ex"}]
      }
    }

    test_pid = self()

    opts = [
      reply: fn _ref, _c, tid, _b ->
        send(test_pid, {:reply, tid})
        :ok
      end,
      resolve: fn _ref, _c, tid ->
        send(test_pid, {:resolve, tid})
        :ok
      end,
      append_event: fn _ -> :ok end,
      mark_dedupe_processed: fn _ -> :ok end
    ]

    assert :ok = AddressReviewHandoff.publish(run, @body_guarded, opts)
    assert_received {:reply, "T1"}
    assert_received {:reply, "T2"}
    assert_received {:resolve, "T1"}
    # path lib/b.ex not in files_changed → not resolved
    refute_received {:resolve, "T2"}
  end

  test "leaves a thread open and errors when output is malformed" do
    opts = [
      reply: fn _ref, _c, _t, _b -> :ok end,
      resolve: fn _ref, _c, _t -> :ok end,
      append_event: fn _ -> :ok end,
      mark_dedupe_processed: fn _ -> :ok end
    ]

    assert {:error, _} = AddressReviewHandoff.publish(@run, "no json here", opts)
  end
end
