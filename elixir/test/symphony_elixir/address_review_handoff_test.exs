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
    payload: %{"project_id" => "proj-1", "threads" => [%{id: "T1"}]}
  }

  @body """
  I addressed the rename.
  {"threads": [{"thread_id": "T1", "reply": "Renamed foo to bar.", "resolved": true}]}
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
