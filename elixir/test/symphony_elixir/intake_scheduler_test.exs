defmodule SymphonyElixir.IntakeSchedulerTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake.Rules
  alias SymphonyElixir.Intake.Scheduler
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{IntegrationConnection, Project}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), intake_effects_enabled: true)
    :ok = Sandbox.checkout(Repo)
    {:ok, project: project!(), connection: jira_connection!()}
  end

  test "rule due times stay independent and a failed Jira scan does not block another rule", %{
    project: project,
    connection: connection
  } do
    now = ~U[2026-09-23 10:00:00Z]
    first = active_rule!(project, connection, "first", DateTime.add(now, 60, :second), 60)
    second = active_rule!(project, connection, "second", DateTime.add(now, 300, :second), 300)
    parent = self()

    runner = fn rule_id ->
      send(parent, {:scan_started, rule_id, self()})

      receive do
        {:finish_scan, ^rule_id, result} ->
          send(parent, {:scan_finished, rule_id, result})
          result
      end
    end

    {:ok, scheduler} = Scheduler.start_link(name: nil, poller: runner, tick_interval_ms: 0, enabled?: true)
    :ok = Sandbox.allow(Repo, self(), scheduler)
    on_exit(fn -> if Process.alive?(scheduler), do: GenServer.stop(scheduler) end)

    assert {:ok, [first_id]} = Scheduler.tick(scheduler, now: DateTime.add(now, 61, :second))
    assert first_id == first.id
    assert_receive {:scan_started, ^first_id, first_worker}
    assert {:error, :scan_in_progress} = Scheduler.check_now(scheduler, first_id)

    assert {:ok, [second_id]} = Scheduler.tick(scheduler, now: DateTime.add(now, 301, :second))
    assert second_id == second.id
    assert_receive {:scan_started, ^second_id, second_worker}
    assert {:ok, []} = Scheduler.tick(scheduler, now: DateTime.add(now, 301, :second))

    send(first_worker, {:finish_scan, first_id, {:error, :jira_unavailable}})
    send(second_worker, {:finish_scan, second_id, {:ok, :completed}})

    assert_receive {:scan_finished, ^first_id, {:error, :jira_unavailable}}
    assert_receive {:scan_finished, ^second_id, {:ok, :completed}}
    assert Process.alive?(scheduler)
    assert Process.alive?(Process.whereis(SymphonyElixir.Orchestrator))
  end

  test "a restarted scheduler discovers due work from persisted rule state", %{project: project, connection: connection} do
    now = ~U[2026-09-23 10:00:00Z]
    rule = active_rule!(project, connection, "restart", DateTime.add(now, -1, :second), 60)
    parent = self()

    runner = fn rule_id ->
      send(parent, {:recovered_scan, rule_id})
      {:ok, :completed}
    end

    {:ok, old_scheduler} = Scheduler.start_link(name: nil, poller: runner, tick_interval_ms: 0, enabled?: true)
    :ok = Sandbox.allow(Repo, self(), old_scheduler)
    GenServer.stop(old_scheduler)

    {:ok, restarted_scheduler} = Scheduler.start_link(name: nil, poller: runner, tick_interval_ms: 0, enabled?: true)
    :ok = Sandbox.allow(Repo, self(), restarted_scheduler)
    on_exit(fn -> if Process.alive?(restarted_scheduler), do: GenServer.stop(restarted_scheduler) end)

    assert {:ok, [rule_id]} = Scheduler.tick(restarted_scheduler, now: now)
    assert rule_id == rule.id
    assert_receive {:recovered_scan, ^rule_id}
  end

  test "an activating rule waits until its persisted retry time", %{project: project, connection: connection} do
    now = ~U[2026-09-23 10:00:00.000000Z]
    due_at = DateTime.add(now, 60, :second)
    rule = activating_rule!(project, connection, "retry", due_at, 60)
    parent = self()

    runner = fn rule_id ->
      send(parent, {:retry_scan_started, rule_id})
      {:ok, :completed}
    end

    {:ok, scheduler} = Scheduler.start_link(name: nil, poller: runner, tick_interval_ms: 0, enabled?: true)
    :ok = Sandbox.allow(Repo, self(), scheduler)
    on_exit(fn -> if Process.alive?(scheduler), do: GenServer.stop(scheduler) end)

    assert {:ok, []} = Scheduler.tick(scheduler, now: now)
    refute_receive {:retry_scan_started, _rule_id}, 0

    assert {:ok, [rule_id]} = Scheduler.tick(scheduler, now: due_at)
    assert rule_id == rule.id
    assert_receive {:retry_scan_started, ^rule_id}
  end

  test "effects kill switch blocks automatic and manual scans", %{project: project, connection: connection} do
    now = ~U[2026-09-23 10:00:00Z]
    rule = active_rule!(project, connection, "effects-disabled", now, 60)
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      intake_enabled: true,
      intake_effects_enabled: false,
      intake_public_url: "https://harmony.example.test"
    )

    {:ok, scheduler} =
      Scheduler.start_link(
        name: nil,
        poller: fn _rule_id -> send(parent, :unexpected_scan) end,
        tick_interval_ms: 0,
        clock: fn -> now end,
        enabled?: true
      )

    :ok = Sandbox.allow(Repo, self(), scheduler)
    on_exit(fn -> if Process.alive?(scheduler), do: GenServer.stop(scheduler) end)

    assert {:ok, []} = Scheduler.tick(scheduler, now: now)
    assert {:error, :effects_disabled} = Scheduler.check_now(scheduler, rule.id)
    refute_receive :unexpected_scan, 0
  end

  test "a repeated manual check while its request is running is rejected without starting another task", %{
    project: project,
    connection: connection
  } do
    now = ~U[2026-09-23 10:00:00Z]
    rule = active_rule!(project, connection, "manual", DateTime.add(now, 300, :second), 300)
    parent = self()

    runner = fn rule_id ->
      send(parent, {:manual_scan_started, rule_id, self()})

      receive do
        {:finish_manual_scan, ^rule_id} ->
          send(parent, {:manual_scan_finished, rule_id})
          :ok
      end
    end

    {:ok, scheduler} =
      Scheduler.start_link(
        name: nil,
        poller: runner,
        tick_interval_ms: 0,
        clock: fn -> now end,
        enabled?: true
      )

    :ok = Sandbox.allow(Repo, self(), scheduler)
    on_exit(fn -> if Process.alive?(scheduler), do: GenServer.stop(scheduler) end)

    assert :accepted = Scheduler.check_now(scheduler, rule.id)
    assert_receive {:manual_scan_started, rule_id, worker}
    assert rule_id == rule.id
    assert {:error, :scan_in_progress} = Scheduler.check_now(scheduler, rule.id)

    send(worker, {:finish_manual_scan, rule.id})
    assert_receive {:manual_scan_finished, rule_id}
    assert rule_id == rule.id
  end

  test "scheduler failure logs only a safe code and rule id", %{project: project, connection: connection} do
    rule = active_rule!(project, connection, "redacted", ~U[2026-09-23 09:59:59.000000Z], 60)
    parent = self()
    secret = "jira-response-must-not-be-logged"
    runner = fn _rule_id -> {:error, %{title: secret, description: secret}} end

    {:ok, scheduler} =
      Scheduler.start_link(
        name: nil,
        poller: runner,
        tick_interval_ms: 0,
        enabled?: true,
        result_observer: fn rule_id, error_code -> send(parent, {:scan_reported, rule_id, error_code}) end
      )

    :ok = Sandbox.allow(Repo, self(), scheduler)
    on_exit(fn -> if Process.alive?(scheduler), do: GenServer.stop(scheduler) end)

    log =
      capture_log(fn ->
        assert {:ok, [rule_id]} = Scheduler.tick(scheduler, now: ~U[2026-09-23 10:00:00Z])
        assert rule_id == rule.id
        assert_receive {:scan_reported, ^rule_id, "scan_failed"}
      end)

    assert log =~ "rule_id=#{rule.id}"
    assert log =~ "error_code=scan_failed"
    refute log =~ secret
  end

  defp active_rule!(project, connection, suffix, due_at, interval_seconds) do
    {:ok, rule} =
      Rules.create(%{
        project_id: project.id,
        jira_connection_id: connection.id,
        name: "Scheduler #{suffix}",
        source_type: "filter",
        source_id: "#{System.unique_integer([:positive])}",
        priority_ids: ["1"],
        interval_seconds: interval_seconds,
        initial_policy: "new_matches_only",
        linear_team_id: "team-id",
        linear_project_id: "project-id",
        linear_todo_state_id: "todo-id",
        linear_hold_label_id: "hold-id",
        email_connection_id: nil,
        email_recipients: [],
        sms_connection_id: nil,
        sms_recipients: []
      })

    rule
    |> Ecto.Changeset.change(%{
      enabled: true,
      activation_status: "idle",
      baseline_generation: Ecto.UUID.generate(),
      next_poll_at: %{due_at | microsecond: {elem(due_at.microsecond, 0), 6}}
    })
    |> Repo.update!()
  end

  defp activating_rule!(project, connection, suffix, due_at, interval_seconds) do
    rule = active_rule!(project, connection, suffix, due_at, interval_seconds)

    rule
    |> Ecto.Changeset.change(%{
      enabled: false,
      activation_status: "activating",
      baseline_generation: nil
    })
    |> Repo.update!()
  end

  defp project! do
    %Project{}
    |> Project.changeset(%{
      slug: "intake-scheduler-#{System.unique_integer([:positive])}",
      forge_owner: "example",
      forge_repo: "harmony",
      forge_base_branch: "main",
      config: %{},
      config_version: 1,
      ui_color: "purple"
    })
    |> Repo.insert!()
  end

  defp jira_connection! do
    %IntegrationConnection{}
    |> IntegrationConnection.changeset(%{
      kind: "jira_cloud",
      name: "Scheduler Jira",
      settings: %{"site_url" => "https://scheduler.atlassian.net", "auth_mode" => "classic"},
      secret: "synthetic-jira-token",
      enabled: true
    })
    |> Repo.insert!()
  end
end
