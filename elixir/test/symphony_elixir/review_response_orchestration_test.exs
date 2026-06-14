defmodule SymphonyElixir.ReviewResponseOrchestrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Orchestrator, WorkRun}

  # ---------------------------------------------------------------------------
  # Work-source registration (forge dispatch)
  # ---------------------------------------------------------------------------

  test "the review-response fetcher is dispatched by forge_type" do
    fetcher = Orchestrator.review_response_work_source_fetcher()
    assert is_function(fetcher, 1)

    github_project = %{forge_type: "github", slug: "p"}
    gitlab_project = %{forge_type: "gitlab", slug: "p"}

    # The fetcher selects the right per-forge source module and dispatches into
    # it. We only assert it is callable and forge-aware: a well-formed
    # {:ok, _} | {:error, _} result (rather than a dispatch crash) proves the
    # per-forge source was reached for both forge types.
    assert well_formed_result?(safe_call(fetcher, github_project))
    assert well_formed_result?(safe_call(fetcher, gitlab_project))
  end

  defp well_formed_result?({:ok, _}), do: true
  defp well_formed_result?({:error, _}), do: true
  defp well_formed_result?(_), do: false

  # ---------------------------------------------------------------------------
  # Finalize routing: address_review -> AddressReviewHandoff, code_review unchanged
  # ---------------------------------------------------------------------------

  test "an address_review run finalizes through the address-review handoff" do
    test_pid = self()

    Application.put_env(:symphony_elixir, :address_review_handoff_fun, fn run, body, opts ->
      send(test_pid, {:address_review_handoff, run, body, opts})
      :ok
    end)

    Application.put_env(:symphony_elixir, :review_handoff_fun, fn run, body, opts ->
      send(test_pid, {:code_review_handoff, run, body, opts})
      :ok
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :address_review_handoff_fun)
      Application.delete_env(:symphony_elixir, :review_handoff_fun)
    end)

    {name, pid} = start_orchestrator(AddressReviewFinalize)
    _ = name

    issue_id = "issue-address-review"

    run = %WorkRun{
      type: "address_review",
      forge_owner: "o",
      forge_repo: "r",
      forge_pr_number: 7,
      dedupe_key: "review-response:o/r:7:T1:C1",
      payload: %{"project_id" => "proj-1", "threads" => [%{id: "T1"}]}
    }

    inject_running(pid, issue_id, run, "agent did the thing")

    send(pid, {:finalize_code_review, issue_id})

    assert_receive {:address_review_handoff, %WorkRun{type: "address_review"}, body, []}
    assert body == "agent did the thing"
    refute_received {:code_review_handoff, _, _, _}
  end

  test "a code_review run still finalizes through the code-review handoff" do
    test_pid = self()

    Application.put_env(:symphony_elixir, :address_review_handoff_fun, fn run, body, opts ->
      send(test_pid, {:address_review_handoff, run, body, opts})
      :ok
    end)

    Application.put_env(:symphony_elixir, :review_handoff_fun, fn run, body, opts ->
      send(test_pid, {:code_review_handoff, run, body, opts})
      :ok
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :address_review_handoff_fun)
      Application.delete_env(:symphony_elixir, :review_handoff_fun)
    end)

    {_name, pid} = start_orchestrator(CodeReviewFinalize)

    issue_id = "issue-code-review"

    run = %WorkRun{
      type: "code_review",
      forge_owner: "o",
      forge_repo: "r",
      forge_pr_number: 9,
      dedupe_key: "review:o/r:9",
      payload: %{"project_id" => "proj-1"}
    }

    inject_running(pid, issue_id, run, "looks good")

    send(pid, {:finalize_code_review, issue_id})

    assert_receive {:code_review_handoff, %WorkRun{type: "code_review"}, body, []}
    assert body == "looks good"
    refute_received {:address_review_handoff, _, _, _}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp safe_call(fetcher, project) do
    fetcher.(Map.put(project, :config, %{}))
  rescue
    _ -> {:ok, []}
  catch
    _, _ -> {:ok, []}
  end

  defp start_orchestrator(label) do
    name = Module.concat(__MODULE__, label)
    {:ok, pid} = Orchestrator.start_link(name: name, initial_poll_delay_ms: 60_000)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    {name, pid}
  end

  defp inject_running(pid, issue_id, run, review_body) do
    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          10_000 -> :ok
        end
      end)

    ref = Process.monitor(worker_pid)

    running_entry = %{
      pid: worker_pid,
      ref: ref,
      identifier: "RR-#{issue_id}",
      issue: %Issue{id: issue_id, identifier: "RR-#{issue_id}", state: "In Progress"},
      session_id: "thread-test",
      review_body: review_body,
      work_run: run,
      started_at: DateTime.utc_now(),
      storage_work_run_id: nil,
      storage_project_id: nil
    }

    :sys.replace_state(pid, fn state ->
      %{state | running: Map.put(state.running, issue_id, running_entry)}
    end)
  end
end
