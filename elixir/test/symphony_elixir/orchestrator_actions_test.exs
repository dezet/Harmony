defmodule SymphonyElixir.OrchestratorActionsTest do
  use SymphonyElixir.TestSupport

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.{Orchestrator, Repo, Storage}
  alias SymphonyElixirWeb.ObservabilityRunPubSub

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_orchestrator(label) do
    name = Module.concat(__MODULE__, label)

    {:ok, pid} =
      Orchestrator.start_link(name: name, initial_poll_delay_ms: 60_000)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    {name, pid}
  end

  defp base_running_entry(issue_id, identifier) do
    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          10_000 -> :ok
        end
      end)

    ref = Process.monitor(worker_pid)

    %{
      pid: worker_pid,
      ref: ref,
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress"},
      session_id: "thread-test",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now(),
      storage_work_run_id: nil,
      storage_project_id: nil
    }
  end

  defp base_retry_entry(identifier) do
    retry_token = make_ref()
    timer_ref = Process.send_after(self(), {:_test_noop}, 60_000)

    %{
      attempt: 1,
      timer_ref: timer_ref,
      retry_token: retry_token,
      due_at_ms: System.monotonic_time(:millisecond) + 60_000,
      identifier: identifier,
      error: "agent exited: :boom"
    }
  end

  defp base_blocked_entry(issue_id, identifier) do
    %{
      issue_id: issue_id,
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress"},
      error: "codex turn requires operator input",
      blocked_at: DateTime.utc_now()
    }
  end

  defp inject_state(pid, fun) do
    :sys.replace_state(pid, fn state -> fun.(state) end)
  end

  # ---------------------------------------------------------------------------
  # stop_run — running
  # ---------------------------------------------------------------------------

  test "stop_run on a running issue returns :ok, cleans up running, adds to completed, broadcasts stopped" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    {name, pid} = start_orchestrator(StopRunning)

    issue_id = "issue-stop-running"
    identifier = "MT-STOP-1"

    :ok = ObservabilityRunPubSub.subscribe(issue_id)

    initial_state = :sys.get_state(pid)

    inject_state(pid, fn state ->
      running_entry = base_running_entry(issue_id, identifier)

      %{
        state
        | running: Map.put(state.running, issue_id, running_entry),
          claimed: MapSet.put(initial_state.claimed, issue_id)
      }
    end)

    result = Orchestrator.stop_run(name, issue_id)
    assert result == :ok

    state = :sys.get_state(pid)
    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)

    assert_receive {:run_status_changed,
                    %{
                      issue_id: ^issue_id,
                      identifier: ^identifier,
                      status: "stopped"
                    }},
                   1_000
  end

  # ---------------------------------------------------------------------------
  # stop_run — running with storage_work_run_id
  # ---------------------------------------------------------------------------

  @tag :db
  test "stop_run on a running issue with storage_work_run_id persists 'stopped' status" do
    :ok = checkout_repo(%{})
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    {:ok, project} =
      Storage.upsert_project(%{
        slug: "stop-test",
        linear_project_slug: "stop-test",
        linear_team_key: "ST",
        linear_human_review_state: "Human Review",
        forge_owner: "dezet",
        forge_repo: "stop-test",
        forge_base_branch: "main",
        config_version: 1,
        config: %{}
      })

    {:ok, work_run} =
      Storage.create_work_run(%{
        project_id: project.id,
        type: "implementation",
        status: "running",
        agent_backend: "codex",
        payload: %{"title" => "Stop test"}
      })

    {name, pid} = start_orchestrator(StopRunningWithStorage)
    Sandbox.allow(Repo, self(), pid)

    issue_id = "issue-stop-running-storage"
    identifier = "MT-STOP-2"
    initial_state = :sys.get_state(pid)

    inject_state(pid, fn state ->
      running_entry =
        base_running_entry(issue_id, identifier)
        |> Map.put(:storage_work_run_id, work_run.id)

      %{
        state
        | running: Map.put(state.running, issue_id, running_entry),
          claimed: MapSet.put(initial_state.claimed, issue_id)
      }
    end)

    :ok = Orchestrator.stop_run(name, issue_id)

    updated = Repo.get(Storage.WorkRun, work_run.id)
    assert updated.status == "stopped"
  end

  # ---------------------------------------------------------------------------
  # stop_run — blocked
  # ---------------------------------------------------------------------------

  test "stop_run on a blocked issue returns :ok, removes from blocked, adds to completed, broadcasts stopped" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    {name, pid} = start_orchestrator(StopBlocked)

    issue_id = "issue-stop-blocked"
    identifier = "MT-STOP-3"

    :ok = ObservabilityRunPubSub.subscribe(issue_id)

    initial_state = :sys.get_state(pid)

    inject_state(pid, fn state ->
      blocked_entry = base_blocked_entry(issue_id, identifier)

      %{
        state
        | blocked: Map.put(state.blocked, issue_id, blocked_entry),
          claimed: MapSet.put(initial_state.claimed, issue_id)
      }
    end)

    result = Orchestrator.stop_run(name, issue_id)
    assert result == :ok

    state = :sys.get_state(pid)
    refute Map.has_key?(state.blocked, issue_id)
    assert MapSet.member?(state.completed, issue_id)

    assert_receive {:run_status_changed,
                    %{
                      issue_id: ^issue_id,
                      identifier: ^identifier,
                      status: "stopped"
                    }},
                   1_000
  end

  # ---------------------------------------------------------------------------
  # stop_run — retrying
  # ---------------------------------------------------------------------------

  test "stop_run on a retrying issue returns :ok, cancels timer, removes from retry, adds to completed, broadcasts stopped" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    {name, pid} = start_orchestrator(StopRetrying)

    issue_id = "issue-stop-retrying"
    identifier = "MT-STOP-4"

    :ok = ObservabilityRunPubSub.subscribe(issue_id)

    inject_state(pid, fn state ->
      retry_entry = base_retry_entry(identifier)

      %{
        state
        | retry_attempts: Map.put(state.retry_attempts, issue_id, retry_entry),
          claimed: MapSet.put(state.claimed, issue_id)
      }
    end)

    result = Orchestrator.stop_run(name, issue_id)
    assert result == :ok

    state = :sys.get_state(pid)
    refute Map.has_key?(state.retry_attempts, issue_id)
    assert MapSet.member?(state.completed, issue_id)

    assert_receive {:run_status_changed,
                    %{
                      issue_id: ^issue_id,
                      identifier: ^identifier,
                      status: "stopped"
                    }},
                   1_000
  end

  # ---------------------------------------------------------------------------
  # stop_run — completed (already_terminal)
  # ---------------------------------------------------------------------------

  test "stop_run on an already-completed issue returns {:error, :already_terminal}" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    {name, pid} = start_orchestrator(StopAlreadyCompleted)

    issue_id = "issue-stop-completed"

    inject_state(pid, fn state ->
      %{state | completed: MapSet.put(state.completed, issue_id)}
    end)

    assert {:error, :already_terminal} = Orchestrator.stop_run(name, issue_id)
  end

  # ---------------------------------------------------------------------------
  # stop_run — unknown
  # ---------------------------------------------------------------------------

  test "stop_run on an unknown issue returns {:error, :run_not_found}" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    {name, _pid} = start_orchestrator(StopUnknown)

    assert {:error, :run_not_found} = Orchestrator.stop_run(name, "issue-does-not-exist")
  end

  test "stop_run returns {:error, :run_not_found} when orchestrator process is down" do
    name = Module.concat(__MODULE__, :StopDown)
    assert {:error, :run_not_found} = Orchestrator.stop_run(name, "issue-any")
  end

  # ---------------------------------------------------------------------------
  # retry_now — retrying
  # ---------------------------------------------------------------------------

  test "retry_now on a retrying issue returns :ok and schedules immediate retry with a new token" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    {name, pid} = start_orchestrator(RetryNowRetrying)

    issue_id = "issue-retry-now"
    identifier = "MT-RETRY-1"

    retry_entry = base_retry_entry(identifier)
    old_token = retry_entry.retry_token

    inject_state(pid, fn state ->
      %{
        state
        | retry_attempts: Map.put(state.retry_attempts, issue_id, retry_entry),
          claimed: MapSet.put(state.claimed, issue_id)
      }
    end)

    result = Orchestrator.retry_now(name, issue_id)
    assert result == :ok

    state = :sys.get_state(pid)

    # Entry still in retry_attempts with a new token (timer fires quickly but may still be there)
    case Map.get(state.retry_attempts, issue_id) do
      nil ->
        # The 0ms timer may have already fired and dispatched; that's also :ok
        :ok

      updated_entry ->
        assert updated_entry.retry_token != old_token
    end
  end

  # ---------------------------------------------------------------------------
  # retry_now — not in retry (running)
  # ---------------------------------------------------------------------------

  test "retry_now on a running issue returns {:error, :not_retrying}" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    {name, pid} = start_orchestrator(RetryNowRunning)

    issue_id = "issue-retry-running"
    identifier = "MT-RETRY-2"

    initial_state = :sys.get_state(pid)

    inject_state(pid, fn state ->
      running_entry = base_running_entry(issue_id, identifier)

      %{
        state
        | running: Map.put(state.running, issue_id, running_entry),
          claimed: MapSet.put(initial_state.claimed, issue_id)
      }
    end)

    assert {:error, :not_retrying} = Orchestrator.retry_now(name, issue_id)
  end

  # ---------------------------------------------------------------------------
  # retry_now — unknown
  # ---------------------------------------------------------------------------

  test "retry_now on an unknown issue returns {:error, :not_retrying}" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    {name, _pid} = start_orchestrator(RetryNowUnknown)

    assert {:error, :not_retrying} = Orchestrator.retry_now(name, "issue-does-not-exist")
  end

  test "retry_now returns {:error, :not_retrying} when orchestrator process is down" do
    name = Module.concat(__MODULE__, :RetryDown)
    assert {:error, :not_retrying} = Orchestrator.retry_now(name, "issue-any")
  end

  # ---------------------------------------------------------------------------
  # Storage.update_work_run_status
  # ---------------------------------------------------------------------------

  @tag :db
  test "Storage.update_work_run_status updates the status of a stored work_run" do
    :ok = checkout_repo(%{})

    {:ok, project} =
      Storage.upsert_project(%{
        slug: "status-update-test",
        linear_project_slug: "status-update-test",
        linear_team_key: "SU",
        linear_human_review_state: "Human Review",
        forge_owner: "dezet",
        forge_repo: "status-update-test",
        forge_base_branch: "main",
        config_version: 1,
        config: %{}
      })

    {:ok, work_run} =
      Storage.create_work_run(%{
        project_id: project.id,
        type: "implementation",
        status: "running",
        agent_backend: "codex",
        payload: %{"title" => "Status update test"}
      })

    assert :ok = Storage.update_work_run_status(work_run.id, "stopped")

    updated = Repo.get(Storage.WorkRun, work_run.id)
    assert updated.status == "stopped"
  end

  @tag :db
  test "Storage.update_work_run_status returns {:error, :not_found} for unknown id" do
    :ok = checkout_repo(%{})

    assert {:error, :not_found} =
             Storage.update_work_run_status(Ecto.UUID.generate(), "stopped")
  end
end
