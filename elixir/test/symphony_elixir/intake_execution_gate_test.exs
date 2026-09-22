defmodule SymphonyElixir.IntakeExecutionGateTest.UnavailableRepo do
  def get_by(_schema, _filters), do: raise("database unavailable")
end

defmodule SymphonyElixir.IntakeExecutionGateTest do
  use SymphonyElixir.TestSupport

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.{Config, Orchestrator, Repo, RuntimePolicy, WorkRun}
  alias SymphonyElixir.Intake.ExecutionGate
  alias SymphonyElixir.WorkSources.LinearIssueSource
  alias SymphonyElixir.Storage.{AutomationRule, IntakeCase, IntegrationConnection, Project}

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "a reserved imported Todo does not start an implementation runner without approval" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    {project, _imported_case, issue} = imported_issue_fixture()
    work_run = WorkRun.from_linear_issue(issue, project_id: project.id)
    parent = self()
    issue_id = issue.id

    configure_issue_runner(parent, issue)
    configure_candidate(issue, work_run)
    {_name, pid} = start_orchestrator()
    send(pid, :run_poll_cycle)

    refute_receive {:runner_started, _runner_pid, ^issue_id}, 500
  end

  test "candidate fetch filters protected cases and keeps unmanaged Todo candidates" do
    project = project!()
    {^project, intake_case, protected_issue} = imported_issue_fixture(project)

    unmanaged_issue = %Issue{
      id: Ecto.UUID.generate(),
      identifier: "OPS-2",
      title: "Ordinary Todo",
      state: "Todo",
      labels: []
    }

    assert {:ok, [run]} =
             LinearIssueSource.fetch_candidates(
               project_id: project.id,
               issue_fetcher: fn -> {:ok, [protected_issue, unmanaged_issue]} end
             )

    assert run.linear_issue_id == unmanaged_issue.id
    assert intake_case.linear_issue_id == protected_issue.id
  end

  test "final retry dispatch rechecks an unapproved imported Todo" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    {project, _intake_case, issue} = imported_issue_fixture()
    parent = self()
    configure_issue_runner(parent, issue)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    {_name, pid} = start_orchestrator()
    retry_token = make_ref()
    timer_ref = Process.send_after(self(), :test_retry_noop, 60_000)

    :sys.replace_state(pid, fn state ->
      %{state | retry_attempts: Map.put(state.retry_attempts, issue.id, retry_entry(retry_token, timer_ref, project.id))}
    end)

    send(pid, {:retry_issue, issue.id, retry_token})
    refute_receive {:runner_started, _runner_pid, _issue_id}, 500
  end

  test "gate remains active after restart while intake is disabled" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    {project, _intake_case, issue} = imported_issue_fixture()
    work_run = WorkRun.from_linear_issue(issue, project_id: project.id)
    parent = self()
    configure_issue_runner(parent, issue)
    configure_candidate(issue, work_run)
    {name, pid} = start_orchestrator()

    send(pid, :run_poll_cycle)
    refute_receive {:runner_started, _runner_pid, _issue_id}, 300

    :ok = GenServer.stop(pid, :normal)
    disable_intake!()
    assert Config.settings!().intake.enabled == false
    assert Config.settings!().intake.effects_enabled == false

    {:ok, restarted_pid} = Orchestrator.start_link(name: name, initial_poll_delay_ms: 60_000)
    :ok = Sandbox.allow(Repo, self(), restarted_pid)

    on_exit(fn ->
      if Process.alive?(restarted_pid), do: GenServer.stop(restarted_pid, :normal)
    end)

    send(restarted_pid, :run_poll_cycle)
    refute_receive {:runner_started, _runner_pid, _issue_id}, 500
    assert {:error, :analysis_only} = ExecutionGate.authorize_implementation(issue, project.id)
  end

  test "removed labels, unlinked markers, foreign projects, and database failures deny" do
    {project, intake_case, _issue} = imported_issue_fixture()
    label_removed_issue = %Issue{id: intake_case.linear_issue_id, identifier: "OPS-1", title: "Imported", state: "Todo", labels: []}

    assert {:error, :analysis_only} = ExecutionGate.authorize_implementation(label_removed_issue, project.id)

    unlinked_marker_issue = %Issue{
      id: Ecto.UUID.generate(),
      identifier: "OPS-3",
      title: "Orphaned import",
      state: "Todo",
      description: "Harmony case: #{Ecto.UUID.generate()}",
      labels: []
    }

    assert {:error, :unlinked_managed_issue} = ExecutionGate.authorize_implementation(unlinked_marker_issue, project.id)
    assert {:error, :project_mismatch} = ExecutionGate.authorize_implementation(label_removed_issue, Ecto.UUID.generate())

    assert {:error, :database_unavailable} =
             ExecutionGate.authorize_implementation(
               %Issue{id: Ecto.UUID.generate(), identifier: "OPS-4", title: "Todo", state: "Todo", labels: []},
               project.id,
               repo: SymphonyElixir.Intake.ExecutionGateTest.UnavailableRepo
             )
  end

  test "approval is versioned and does not bypass ordinary dispatch conditions" do
    project = project!()
    {_project, intake_case, issue} = imported_issue_fixture(project, repair_approved_at: now(), repair_approved_version: 1)

    assert :ok = ExecutionGate.authorize_implementation(issue, project.id)

    base_state = %Orchestrator.State{
      max_concurrent_agents: 2,
      running: %{},
      claimed: MapSet.new(),
      blocked: %{}
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, base_state)
    refute Orchestrator.should_dispatch_issue_for_test(%{issue | state: "Backlog"}, base_state)
    refute Orchestrator.should_dispatch_issue_for_test(%{issue | assigned_to_worker: false}, base_state)
    refute Orchestrator.should_dispatch_issue_for_test(%{issue | blocked_by: [%{state: "In Progress"}]}, base_state)

    full_state = %{base_state | max_concurrent_agents: 0}
    refute Orchestrator.should_dispatch_issue_for_test(issue, full_state)

    assert intake_case.repair_approved_version == intake_case.analysis_version

    {_project, _stale_case, stale_issue} =
      imported_issue_fixture(project,
        analysis_version: 2,
        repair_approved_at: now(),
        repair_approved_version: 1
      )

    assert {:error, :stale_approval} = ExecutionGate.authorize_implementation(stale_issue, project.id)

    assert {:error, :fork_pr_requires_repair_branch} =
             RuntimePolicy.RepoPolicy.authorize_push(%{
               head_repo_full_name: "fork/repo",
               base_repo_full_name: "base/repo",
               head_ref: "repair",
               base_ref: "main",
               protected_branches: ["main"]
             })
  end

  test "an unmanaged Todo still starts an implementation runner" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    project = project!()

    issue = %Issue{
      id: Ecto.UUID.generate(),
      identifier: "OPS-9",
      title: "Ordinary Todo",
      state: "Todo",
      labels: []
    }

    parent = self()
    configure_issue_runner(parent, issue)
    configure_candidate(issue, WorkRun.from_linear_issue(issue, project_id: project.id))
    {_name, pid} = start_orchestrator()
    send(pid, :run_poll_cycle)

    assert_receive {:runner_started, _runner_pid, issue_id}, 1_000
    assert issue_id == issue.id
  end

  defp project! do
    %Project{}
    |> Project.changeset(%{
      slug: "execution-gate-#{System.unique_integer([:positive])}",
      linear_project_slug: "linear-project",
      linear_team_key: "OPS",
      forge_owner: "example",
      forge_repo: "repo",
      forge_base_branch: "main",
      config_version: 1,
      config: %{}
    })
    |> Repo.insert!()
  end

  defp imported_issue_fixture(project \\ nil, attrs \\ []) do
    project = project || project!()
    connection = connection!()
    rule = rule!(project, connection)
    linear_issue_id = Ecto.UUID.generate()
    imported_case = intake_case!(project, rule, connection, linear_issue_id, attrs)

    issue = %Issue{
      id: imported_case.linear_issue_id,
      identifier: "OPS-1",
      title: "Imported issue",
      description: "Harmony case: #{imported_case.id}",
      state: "Todo",
      labels: ["harmony:analysis-only"]
    }

    {project, imported_case, issue}
  end

  defp configure_issue_runner(parent, issue) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    Application.put_env(:symphony_elixir, :agent_runner_fun, fn started_issue, _recipient, _opts ->
      send(parent, {:runner_started, self(), started_issue.id})
      :ok
    end)
  end

  defp configure_candidate(issue, work_run) do
    Application.put_env(:symphony_elixir, :work_source_fetchers, [fn -> {:ok, [work_run]} end])
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
  end

  defp start_orchestrator do
    name = Module.concat(__MODULE__, "GateOrchestrator#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name, initial_poll_delay_ms: 60_000)
    :ok = Sandbox.allow(Repo, self(), pid)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    {name, pid}
  end

  defp disable_intake! do
    path = Workflow.workflow_file_path()
    contents = File.read!(path)
    [front_matter, body] = String.split(contents, "\n---\n", parts: 2)
    File.write!(path, front_matter <> "\nintake:\n  enabled: false\n  effects_enabled: false\n---\n" <> body)
    SymphonyElixir.WorkflowStore.force_reload()
  end

  defp retry_entry(token, timer_ref, project_id) do
    %{
      attempt: 1,
      timer_ref: timer_ref,
      retry_token: token,
      due_at_ms: System.monotonic_time(:millisecond) + 60_000,
      identifier: "OPS-1",
      error: nil,
      gate_project_id: project_id,
      worker_host: nil,
      workspace_path: nil
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp connection! do
    %IntegrationConnection{}
    |> IntegrationConnection.changeset(%{
      kind: "jira_cloud",
      name: "Execution gate Jira",
      settings: %{site_url: "https://execution-gate-#{System.unique_integer([:positive])}.atlassian.net"},
      enabled: true
    })
    |> Repo.insert!()
  end

  defp rule!(project, connection) do
    %AutomationRule{}
    |> AutomationRule.changeset(%{
      project_id: project.id,
      jira_connection_id: connection.id,
      name: "Execution gate rule",
      source_type: "board",
      source_id: "42",
      priority_ids: ["1"],
      interval_seconds: 300,
      initial_policy: "new_matches_only",
      linear_team_id: "team-id",
      linear_project_id: "project-id",
      linear_todo_state_id: "todo-id",
      linear_hold_label_id: "hold-id"
    })
    |> Repo.insert!()
  end

  defp intake_case!(project, rule, connection, linear_issue_id, attrs) do
    timestamp = now()

    %IntakeCase{}
    |> IntakeCase.changeset(
      Map.merge(
        %{
          project_id: project.id,
          rule_id: rule.id,
          jira_connection_id: connection.id,
          jira_issue_id: "OPS-1",
          jira_key: "OPS-1",
          jira_url: "https://execution-gate.atlassian.net/browse/OPS-1",
          title: "Imported issue",
          description_text: "Imported for execution gate regression",
          priority_id: "1",
          priority_name: "Highest",
          jira_updated_at: timestamp,
          detected_at: timestamp,
          rule_snapshot: %{name: rule.name},
          linear_issue_id: linear_issue_id,
          analysis_version: 1,
          analysis_status: "ready",
          lock_version: 1
        },
        Map.new(attrs)
      )
    )
    |> Repo.insert!()
  end
end
