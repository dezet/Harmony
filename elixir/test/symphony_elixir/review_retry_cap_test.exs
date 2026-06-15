defmodule SymphonyElixir.ReviewRetryCapTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Storage, WorkRun}
  alias SymphonyElixir.Workflows.AddressReviewHandoff

  @dedupe_key "review-response:o/r:7:T1:C1"

  # Agent claims resolved but does NOT change the file → thread stays open, attempt increments.
  @unaddressed ~s({"threads":[{"thread_id":"T1","reply":"hmm","resolved":true}],"files_changed":[]})

  @tag :db
  test "an unaddressed thread is left open and its attempt count increments" do
    :ok = checkout_repo(%{})
    project_id = insert_project!()
    run = run_for(project_id)

    opts = [reply: fn _ref, _c, _t, _b -> :ok end, resolve: fn _r, _c, _t -> :ok end]

    assert :ok = AddressReviewHandoff.publish(run, @unaddressed, opts)
    assert Storage.dedupe_status(project_id, @dedupe_key) != "processed"
    assert Storage.review_attempt_count(project_id, @dedupe_key) == 1
  end

  @tag :db
  test "reaching 3 attempts marks processed and posts a needs-human note" do
    :ok = checkout_repo(%{})
    project_id = insert_project!()
    run = run_for(project_id)
    test_pid = self()

    opts = [
      reply: fn _ref, _c, _t, b ->
        send(test_pid, {:reply, b})
        :ok
      end,
      resolve: fn _r, _c, _t -> :ok end
    ]

    for _ <- 1..3, do: AddressReviewHandoff.publish(run, @unaddressed, opts)

    assert Storage.dedupe_status(project_id, @dedupe_key) == "processed"

    # the 3rd attempt posts a needs-human note in addition to the per-thread reply
    assert_received {:reply, body}
                    when is_binary(body)

    assert drain_until_needs_human()
  end

  defp drain_until_needs_human do
    receive do
      {:reply, body} ->
        String.contains?(body, "needs human review") or drain_until_needs_human()
    after
      0 -> false
    end
  end

  defp insert_project! do
    {:ok, project} =
      Storage.upsert_project(%{
        "slug" => "retry-cap-#{System.unique_integer([:positive])}",
        "forge_type" => "github",
        "forge_owner" => "o",
        "forge_repo" => "r",
        "forge_base_branch" => "main",
        "config_version" => 1,
        "config" => %{}
      })

    project.id
  end

  defp run_for(project_id) do
    %WorkRun{
      type: "address_review",
      forge_owner: "o",
      forge_repo: "r",
      forge_pr_number: 7,
      dedupe_key: @dedupe_key,
      payload: %{"project_id" => project_id, "threads" => [%{id: "T1", path: "lib/a.ex"}]}
    }
  end
end
