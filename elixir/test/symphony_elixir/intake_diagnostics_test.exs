defmodule SymphonyElixir.IntakeDiagnosticsTest do
  use SymphonyElixir.TestSupport

  import Ecto.Query
  import SymphonyElixir.CasesFixtures

  alias SymphonyElixir.Intake.Diagnostics
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{AutomationRule, AutomationScan, IntegrationDelivery}
  alias SymphonyElixirWeb.Presenter

  setup :checkout_repo

  @canaries [
    "CANARY-TITLE",
    "CANARY-DESCRIPTION",
    "canary-recipient@example.test",
    "+19995550999",
    "synthetic-jira-token",
    "oncall@example.test"
  ]

  defp set_delivery!(delivery, fields), do: Repo.update_all(from(d in IntegrationDelivery, where: d.id == ^delivery.id), set: fields)

  defp scan!(rule, mode, status, started_at, duration_ms) do
    %AutomationScan{}
    |> AutomationScan.changeset(%{
      rule_id: rule.id,
      rule_config_version: rule.config_version,
      mode: mode,
      status: status,
      started_at: started_at,
      finished_at: DateTime.add(started_at, duration_ms, :millisecond),
      error_code: if(status == "failed", do: "jira_unavailable")
    })
    |> Repo.insert!()
  end

  # One project with a display name, one rule with two finished scans and a
  # stale lease, a second rule that never ran, and effects in every state.
  defp seed! do
    scope = scope!(%{display_name: "Finanse"})
    first = intake_case!(scope, %{title: "CANARY-TITLE", description_text: "CANARY-DESCRIPTION"})
    second = intake_case!(scope)

    oldest = delivery!(first, "email", "pending", %{recipient: "canary-recipient@example.test"})
    set_delivery!(oldest, inserted_at: at(30))
    retry = delivery!(first, "sms", "retry_wait", %{recipient: "+19995550999"})
    set_delivery!(retry, inserted_at: at(10))
    paused = delivery!(first, "email", "paused")
    set_delivery!(paused, inserted_at: at(5))
    delivery!(first, "email", "unknown")
    delivery!(first, "jira_comment", "failed")
    delivery!(first, "sms", "succeeded")
    live = delivery!(first, "linear_create", "running")
    set_delivery!(live, lease_token: "live", lease_until: at(-5))
    stale = delivery!(second, "email", "running")
    set_delivery!(stale, lease_token: "stale", lease_until: at(5))
    analysis = delivery!(first, "analysis", "running")
    set_delivery!(analysis, lease_token: "analysis", lease_until: at(-5))
    queued_analysis = delivery!(second, "analysis", "pending")
    set_delivery!(queued_analysis, inserted_at: at(1))

    Repo.update_all(from(r in AutomationRule, where: r.id == ^scope.rule.id),
      set: [
        enabled: true,
        last_success_at: at(15),
        next_poll_at: at(-5),
        lease_token: "rule-lease",
        lease_until: at(1)
      ]
    )

    scan!(scope.rule, "poll", "succeeded", at(20), 1_500)
    scan!(scope.rule, "poll", "failed", at(16), 2_500)
    scan!(scope.rule, "preview", "succeeded", at(2), 100)

    idle = scope!()
    Repo.update_all(from(r in AutomationRule, where: r.id == ^idle.rule.id), set: [name: "Zapasowa reguła"])

    %{scope: scope, idle: idle}
  end

  defp snapshot, do: Diagnostics.snapshot(now: base_time(), intake_enabled: false, effects_enabled: false, analysis_enabled: false)

  describe "snapshot/1" do
    test "counts effect queues per operation and status in PostgreSQL" do
      seed!()
      snapshot = snapshot()

      queues = Map.new(snapshot.queues, &{&1.operation, &1})
      assert Enum.map(snapshot.queues, & &1.operation) == ~w(linear_create analysis jira_comment email sms)

      assert %{pending: 1, retry_wait: 0, running: 1, paused: 1, unknown: 1, failed: 0} = queues["email"]
      assert %{pending: 0, retry_wait: 1, running: 0, paused: 0, unknown: 0, failed: 0} = queues["sms"]
      assert %{failed: 1, pending: 0} = queues["jira_comment"]
      assert %{running: 1, pending: 0} = queues["linear_create"]
      assert %{running: 1, pending: 1} = queues["analysis"]
      assert queues["email"].oldest_waiting_at == at(30)
      assert queues["linear_create"].oldest_waiting_at == nil
    end

    test "reports backlog, oldest waiting effect, unknown results and stale leases" do
      seed!()
      snapshot = snapshot()

      assert snapshot.backlog == %{total: 4, oldest_waiting_at: at(30)}
      assert snapshot.unknown == 1
      assert snapshot.stale_leases == %{deliveries: 1, rules: 1}
    end

    test "shows the analysis pool against its claim limit" do
      seed!()

      assert snapshot().analysis == %{active: 1, limit: 1, queued: 1}
    end

    test "groups channel errors by operation and safe error code" do
      seed!()

      assert Enum.sort_by(snapshot().channel_errors, & &1.operation) == [
               %{operation: "email", error_code: "synthetic_failure", count: 1},
               %{operation: "jira_comment", error_code: "synthetic_failure", count: 1},
               %{operation: "sms", error_code: "synthetic_failure", count: 1}
             ]
    end

    test "lists every rule with its last success and last finished scan, not a preview" do
      %{scope: scope, idle: idle} = seed!()
      rules = Map.new(snapshot().rules, &{&1.id, &1})

      active = rules[scope.rule.id]
      assert active.name == "Pilne zgłoszenia"
      assert active.project == %{id: scope.project.id, slug: scope.project.slug, name: "Finanse"}
      assert active.enabled
      assert active.last_success_at == at(15)
      assert active.next_poll_at == at(-5)
      assert active.last_scan.status == "failed"
      assert active.last_scan.mode == "poll"
      assert active.last_scan.duration_ms == 2_500
      assert active.last_scan.error_code == "jira_unavailable"

      never_ran = rules[idle.rule.id]
      assert never_ran.name == "Zapasowa reguła"
      assert never_ran.project.name == idle.project.slug
      assert never_ran.last_success_at == nil
      assert never_ran.last_scan == nil
    end

    test "reports the runtime switches without changing them" do
      assert %{intake_enabled: false, effects_enabled: false, analysis_enabled: false} = snapshot().switches

      opts = [now: base_time(), intake_enabled: true, effects_enabled: false, analysis_enabled: true]
      switches = Diagnostics.snapshot(opts).switches
      assert %{intake_enabled: true, effects_enabled: false, analysis_enabled: true} = switches
    end

    test "an empty database is all zeros, not an error" do
      snapshot = snapshot()

      assert snapshot.backlog == %{total: 0, oldest_waiting_at: nil}
      assert snapshot.unknown == 0
      assert snapshot.rules == []
      assert snapshot.channel_errors == []
      assert Enum.all?(snapshot.queues, &(&1.pending + &1.retry_wait + &1.running + &1.paused + &1.unknown + &1.failed == 0))
    end
  end

  describe "Presenter.intake_diagnostics_payload/1" do
    test "matches the frontend fixture keys and leaks no content, recipients or secrets" do
      seed!()
      payload = Presenter.intake_diagnostics_payload(snapshot())
      json = Jason.encode!(payload)

      for canary <- @canaries, do: refute(json =~ canary, canary)

      fixture =
        Path.expand("../../assets/src/test/fixtures/intake_diagnostics.fixture.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()

      decoded = Jason.decode!(json)
      assert_same_keys(decoded, fixture)
      assert_same_keys(hd(decoded["queues"]), hd(fixture["queues"]))
      assert_same_keys(hd(decoded["channel_errors"]), hd(fixture["channel_errors"]))

      rule = Enum.find(decoded["rules"], &(&1["last_scan"] != nil))
      assert_same_keys(rule, hd(fixture["rules"]))
      assert_same_keys(rule["last_scan"], hd(fixture["rules"])["last_scan"])
      assert_same_keys(rule["project"], hd(fixture["rules"])["project"])

      assert decoded["backlog"]["oldest_waiting_at"] == "2026-09-22T09:30:00Z"
      assert rule["last_success_at"] == "2026-09-22T09:45:00Z"
    end
  end

  describe "state payload" do
    test "adds the intake diagnostics next to the orchestrator snapshot" do
      write_workflow_file!(Workflow.workflow_file_path(), intake_enabled: false, intake_effects_enabled: false)
      seed!()
      name = Module.concat(__MODULE__, :Orchestrator)
      {:ok, pid} = Orchestrator.start_link(name: name, initial_poll_delay_ms: 60_000)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

      payload = Presenter.state_payload(name, 1_000)

      assert %{counts: %{running: 0}, intake: intake} = payload
      assert intake.switches == %{intake_enabled: false, effects_enabled: false, analysis_enabled: false}
      assert intake.backlog.total == 4
      refute Jason.encode!(payload) =~ "CANARY-TITLE"
    end
  end

  defp assert_same_keys(actual, expected) do
    assert Enum.sort(Map.keys(actual)) == Enum.sort(Map.keys(expected))
  end
end
