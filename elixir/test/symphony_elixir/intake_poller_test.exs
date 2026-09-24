defmodule SymphonyElixir.IntakePollerTest do
  use SymphonyElixir.TestSupport

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake.Poller
  alias SymphonyElixir.Intake.Rules
  alias SymphonyElixir.Repo

  alias SymphonyElixir.Storage.{
    AutomationRule,
    AutomationScan,
    IntakeAnalysis,
    IntakeCase,
    IntakeEvent,
    IntegrationConnection,
    IntegrationDelivery,
    JiraObservation,
    Project
  }

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), intake_effects_enabled: true)
    :ok = Sandbox.checkout(Repo)
    {:ok, rule: rule!()}
  end

  test "an old low-priority issue promoted to P1 after baseline creates one case", %{rule: rule} do
    assert {:ok, activating_rule} = Rules.activate(rule)
    assert activating_rule.activation_status == "activating"
    refute activating_rule.enabled

    assert {:ok, baseline} = Poller.run(rule.id, poll_opts([page([])]))
    assert baseline.mode == "baseline"
    assert baseline.status == "succeeded"

    active_rule = Repo.get!(AutomationRule, rule.id)
    assert active_rule.enabled
    assert active_rule.activation_status == "idle"

    assert {:ok, scan} = Poller.run(rule.id, poll_opts([page([jira_issue("1")])]))
    assert scan.mode == "poll"
    assert scan.accepted_count == 1

    intake_case = Repo.one!(IntakeCase)
    assert intake_case.priority_id == "1"
    assert intake_case.description_text == ""
    assert Ecto.UUID.cast!(intake_case.linear_issue_id) == intake_case.linear_issue_id

    analysis = Repo.one!(from(analysis in IntakeAnalysis, where: analysis.case_id == ^intake_case.id))
    assert analysis.status == "queued"
    assert analysis.version == 1
    assert analysis.model == "synthetic-test-model"
    assert analysis.effort == "low"
    assert analysis.input_snapshot["description_text"] == ""

    deliveries =
      Repo.all(
        from(delivery in IntegrationDelivery,
          where: delivery.case_id == ^intake_case.id,
          select: {delivery.operation, delivery.status}
        )
      )

    assert Enum.sort(deliveries) == [{"analysis", "pending"}, {"linear_create", "pending"}]

    events =
      Repo.all(
        from(event in IntakeEvent,
          where: event.case_id == ^intake_case.id,
          select: event.type
        )
      )

    assert Enum.sort(events) == ["analysis_queued", "case_detected", "delivery_queued", "delivery_queued"]
    assert Repo.aggregate(JiraObservation, :count, :id) == 1
  end

  test "Jira timestamps with offsets are normalized to UTC exactly once", %{rule: rule} do
    assert {:ok, include_rule} = Rules.patch(rule, %{initial_policy: "include_existing"})
    assert {:ok, activating} = Rules.activate(include_rule)
    issue = put_in(jira_issue("1")["fields"]["updated"], "2026-09-23T09:00:00+02:00")

    assert {:ok, _scan} = Poller.run(activating.id, poll_opts([page([issue])]))

    assert Repo.one!(IntakeCase).jira_updated_at == ~U[2026-09-23 07:00:00.000000Z]
  end

  test "effects switch blocks include-existing baseline before any Jira request", %{rule: rule} do
    assert {:ok, include_rule} = Rules.patch(rule, %{initial_policy: "include_existing"})

    activating =
      include_rule
      |> Ecto.Changeset.change(%{activation_status: "activating"})
      |> Repo.update!()

    write_workflow_file!(Workflow.workflow_file_path(),
      intake_enabled: true,
      intake_effects_enabled: false,
      intake_public_url: "https://harmony.example.test"
    )

    {:ok, request_count} = Agent.start_link(fn -> 0 end)

    assert {:error, :effects_disabled} =
             Poller.run(
               activating.id,
               poll_opts(
                 [page([jira_issue("1")])],
                 request_fun: fn request ->
                   Agent.update(request_count, &(&1 + 1))

                   case Keyword.fetch!(request, :method) do
                     :get -> {:ok, %{status: 200, body: %{"filter" => %{"id" => "77"}}}}
                     :post -> {:ok, %{status: 200, body: page([jira_issue("1")])}}
                   end
                 end
               )
             )

    assert Agent.get(request_count, & &1) == 0
    assert Repo.aggregate(AutomationScan, :count, :id) == 0
    assert Repo.aggregate(IntakeCase, :count, :id) == 0
    assert Repo.aggregate(IntegrationDelivery, :count, :id) == 0
  end

  test "effects switch disabled during qualification rolls back case and deliveries", %{rule: rule} do
    assert {:ok, include_rule} = Rules.patch(rule, %{initial_policy: "include_existing"})
    assert {:ok, activating} = Rules.activate(include_rule)

    uuid_fun = fn ->
      write_workflow_file!(Workflow.workflow_file_path(),
        intake_enabled: true,
        intake_effects_enabled: false,
        intake_public_url: "https://harmony.example.test"
      )

      Ecto.UUID.generate()
    end

    assert {:error, :effects_disabled} =
             Poller.run(activating.id, poll_opts([page([jira_issue("1")])], uuid_fun: uuid_fun))

    scan = Repo.one!(AutomationScan)
    assert scan.mode == "baseline"
    assert scan.status == "failed"
    assert scan.error_code == "effects_disabled"
    refute Repo.get!(AutomationRule, rule.id).enabled
    assert is_nil(Repo.get!(AutomationRule, rule.id).baseline_generation)
    assert Repo.aggregate(IntakeCase, :count, :id) == 0
    assert Repo.aggregate(IntegrationDelivery, :count, :id) == 0
  end

  test "Jira Retry-After extends but never shortens a rule interval", %{rule: rule} do
    due_times =
      Enum.map(
        [
          {"43", "30", ~U[2026-09-23 10:00:00.000000Z], 60},
          {"44", "3600", ~U[2026-09-23 10:00:00.000000Z], 3_600},
          {"45", "Wed, 23 Sep 2026 11:30:00 GMT", ~U[2026-09-23 10:00:00.000000Z], 5_400},
          {"46", "Wed, 23 Sep 2026 11:00:00 GMT", ~U[2026-09-23 10:00:00.500000Z], 3_600},
          {"47", "Wednesday, 23-Sep-26 11:30:00 GMT", ~U[2026-09-23 10:00:00.000000Z], 5_400},
          {"48", "Wed Sep 23 11:30:00 2026", ~U[2026-09-23 10:00:00.000000Z], 5_400},
          {"49", "not a date", ~U[2026-09-23 10:00:00.000000Z], 60}
        ],
        fn {source_id, retry_after, now, expected_seconds} ->
          assert {:ok, candidate} = create_rule!(rule, %{source_id: source_id, interval_seconds: 60})
          assert {:ok, activating} = Rules.activate(candidate)
          response = {:http, 429, %{"retry-after" => [retry_after]}, %{"secret" => "must-not-escape"}}

          assert {:error, %{kind: :http_status, status: 429} = error} =
                   Poller.run(activating.id, poll_opts([response], clock: fn -> now end))

          refute inspect(error) =~ "must-not-escape"
          due_at = Repo.get!(AutomationRule, candidate.id).next_poll_at
          assert due_at == DateTime.add(now, expected_seconds, :second)
          due_at
        end
      )

    assert due_times == [
             ~U[2026-09-23 10:01:00.000000Z],
             ~U[2026-09-23 11:00:00.000000Z],
             ~U[2026-09-23 11:30:00.000000Z],
             ~U[2026-09-23 11:00:00.500000Z],
             ~U[2026-09-23 11:30:00.000000Z],
             ~U[2026-09-23 11:30:00.000000Z],
             ~U[2026-09-23 10:01:00.000000Z]
           ]
  end

  test "Jira Retry-After HTTP-date accepts a leap second", %{rule: rule} do
    assert {:ok, activating} = Rules.activate(rule)
    now = ~U[2015-06-30 23:00:00.000000Z]
    response = {:http, 429, %{"retry-after" => ["Tue, 30 Jun 2015 23:59:60 GMT"]}, %{}}

    assert {:error, %{kind: :http_status, status: 429}} =
             Poller.run(activating.id, poll_opts([response], clock: fn -> now end))

    assert Repo.get!(AutomationRule, rule.id).next_poll_at == ~U[2015-07-01 00:00:00.000000Z]
  end

  test "an unexpected Jira fetch exception fails the claimed scan and releases its lease", %{rule: rule} do
    assert {:ok, activating} = Rules.activate(rule)
    request_fun = fn _request -> raise "secret provider response" end

    result = Poller.run(activating.id, poll_opts([], request_fun: request_fun))

    assert result == {:error, :unexpected_scan_failure}
    refute inspect(result) =~ "secret provider response"

    failed_scan = Repo.one!(from(scan in AutomationScan, where: scan.rule_id == ^rule.id))
    assert failed_scan.status == "failed"
    assert failed_scan.error_code == "unexpected_scan_failure"

    failed_rule = Repo.get!(AutomationRule, rule.id)
    assert failed_rule.last_error_code == "unexpected_scan_failure"
    assert is_nil(failed_rule.lease_token)
    assert is_nil(failed_rule.lease_until)

    assert {:ok, recovered} = Poller.run(rule.id, poll_opts([page([])]))
    assert recovered.status == "succeeded"

    throw_result =
      Poller.run(rule.id, poll_opts([], request_fun: fn _request -> throw("secret provider throw") end))

    assert throw_result == {:error, :unexpected_scan_failure}
    refute inspect(throw_result) =~ "secret provider throw"

    failed_poll =
      Repo.one!(
        from(scan in AutomationScan,
          where: scan.rule_id == ^rule.id and scan.status == "failed" and scan.mode == "poll"
        )
      )

    assert failed_poll.error_code == "unexpected_scan_failure"
    assert is_nil(Repo.get!(AutomationRule, rule.id).lease_token)

    assert {:ok, recovered_poll} = Poller.run(rule.id, poll_opts([page([])]))
    assert recovered_poll.status == "succeeded"
  end

  test "new_matches_only excludes baseline matches while include_existing imports them once", %{rule: rule} do
    assert {:ok, activating} = Rules.activate(rule)
    issue_page = page([jira_issue("1")])

    assert {:ok, baseline} = Poller.run(activating.id, poll_opts([issue_page]))
    assert baseline.mode == "baseline"
    assert baseline.accepted_count == 0
    assert Repo.aggregate(IntakeCase, :count, :id) == 0

    observation = Repo.one!(JiraObservation)
    assert observation.baseline_excluded
    assert observation.generation == Repo.get!(AutomationRule, rule.id).baseline_generation

    assert {:ok, scan} = Poller.run(rule.id, poll_opts([issue_page]))
    assert scan.mode == "poll"
    assert scan.accepted_count == 0
    assert Repo.aggregate(IntakeCase, :count, :id) == 0

    assert {:ok, include_rule} = create_rule!(rule, %{source_id: "43", initial_policy: "include_existing"})
    assert {:ok, include_activating} = Rules.activate(include_rule)
    assert {:ok, included} = Poller.run(include_activating.id, poll_opts([issue_page]))
    assert included.mode == "baseline"
    assert included.accepted_count == 1
    assert Repo.aggregate(IntakeCase, :count, :id) == 1

    assert {:ok, repeated} = Poller.run(include_activating.id, poll_opts([issue_page]))
    assert repeated.mode == "poll"
    assert repeated.accepted_count == 0
    assert Repo.aggregate(IntakeCase, :count, :id) == 1
  end

  test "a failed second baseline page does not activate its generation and retry scans all pages", %{rule: rule} do
    assert {:ok, activating} = Rules.activate(rule)
    first_page = page([jira_issue("1")], next_token: "second")

    assert {:error, %{kind: :http_status, status: 503}} =
             Poller.run(activating.id, poll_opts([first_page, {:http, 503, %{}}]))

    failed_rule = Repo.get!(AutomationRule, rule.id)
    refute failed_rule.enabled
    assert failed_rule.activation_status == "activating"
    assert is_nil(failed_rule.baseline_generation)
    assert is_nil(failed_rule.last_success_at)
    assert Repo.aggregate(IntakeCase, :count, :id) == 0

    incomplete_scan = Repo.one!(from(scan in AutomationScan, where: scan.status == "failed"))
    assert incomplete_scan.mode == "baseline"
    assert incomplete_scan.error_code == "http_status"
    assert Repo.one!(JiraObservation).generation == incomplete_scan.generation

    retry_pages = [first_page, page([])]
    assert {:ok, successful} = Poller.run(rule.id, poll_opts(retry_pages))
    assert successful.mode == "baseline"
    assert successful.status == "succeeded"
    assert Repo.get!(AutomationRule, rule.id).baseline_generation == successful.generation
    assert Repo.one!(JiraObservation).generation == successful.generation
  end

  test "a failed poll keeps the previous last success timestamp", %{rule: rule} do
    assert {:ok, activating} = Rules.activate(rule)
    assert {:ok, baseline} = Poller.run(activating.id, poll_opts([page([])]))
    successful_at = Repo.get!(AutomationRule, rule.id).last_success_at

    assert {:error, %{kind: :http_status, status: 503}} =
             Poller.run(rule.id, poll_opts([{:http, 503, %{}}]))

    failed_rule = Repo.get!(AutomationRule, rule.id)
    assert failed_rule.last_success_at == successful_at
    assert failed_rule.last_success_at == baseline.finished_at
    assert failed_rule.last_error_code == "http_status"
  end

  test "key changes, priority transitions, repeated pages, and overlapping sources still make one case", %{rule: rule} do
    assert {:ok, rule} = Rules.patch(rule, %{priority_ids: ["1", "2"]})
    assert {:ok, activating} = Rules.activate(rule)
    assert {:ok, _baseline} = Poller.run(rule.id, poll_opts([page([])]))

    duplicate_pages = [
      page([jira_issue("1", "OPS-1")], next_token: "repeat"),
      page([jira_issue("1", "OPS-2")])
    ]

    assert {:ok, duplicate_scan} = Poller.run(rule.id, poll_opts(duplicate_pages))
    assert duplicate_scan.accepted_count == 1
    assert Repo.aggregate(IntakeCase, :count, :id) == 1

    assert {:ok, downranked} = Poller.run(rule.id, poll_opts([page([jira_issue("2", "OPS-3")])]))
    assert downranked.accepted_count == 0
    assert {:ok, promoted} = Poller.run(rule.id, poll_opts([page([jira_issue("1", "OPS-4")])]))
    assert promoted.accepted_count == 0
    assert Repo.aggregate(IntakeCase, :count, :id) == 1

    assert {:ok, second_rule} = create_rule!(activating, %{source_id: "43", priority_ids: ["1", "2"]})
    assert {:ok, second_activating} = Rules.activate(second_rule)
    assert {:ok, _second_baseline} = Poller.run(second_activating.id, poll_opts([page([])]))
    assert {:ok, linked_scan} = Poller.run(second_activating.id, poll_opts([page([jira_issue("1", "OPS-5")])]))
    assert linked_scan.accepted_count == 0
    assert Repo.aggregate(IntakeCase, :count, :id) == 1

    already_linked =
      Repo.one!(
        from(event in IntakeEvent,
          where: event.rule_id == ^second_rule.id and event.type == "already_linked"
        )
      )

    assert already_linked.payload["jira_key"] == "OPS-5"
  end

  test "scan limits fail without a successful baseline", %{rule: rule} do
    assert {:ok, activating} = Rules.activate(rule)
    oversized_page = page(List.duplicate(jira_issue("1"), 10_001))

    assert {:error, %{kind: :scan_limit_exceeded}} = Poller.run(rule.id, poll_opts([oversized_page]))
    assert Repo.aggregate(JiraObservation, :count, :id) == 0
    assert Repo.aggregate(IntakeCase, :count, :id) == 0
    assert is_nil(Repo.get!(AutomationRule, rule.id).baseline_generation)
    assert Repo.get!(AutomationRule, rule.id).last_error_code == "scan_limit_exceeded"

    time_limit_opts = poll_opts([page([jira_issue("1")])], monotonic_clock: over_time_clock())
    assert {:error, %{kind: :scan_limit_exceeded}} = Poller.run(activating.id, time_limit_opts)
    assert Repo.aggregate(IntakeCase, :count, :id) == 0
    assert is_nil(Repo.get!(AutomationRule, rule.id).last_success_at)

    assert {:ok, fresh_rule} = create_rule!(activating, %{source_id: "44"})
    assert {:ok, fresh_activating} = Rules.activate(fresh_rule)
    first_page = page([jira_issue("1"), jira_issue("1")], next_token: "second")
    opts = poll_opts([first_page, page([jira_issue("1")])], max_issues: 2)

    assert {:error, %{kind: :scan_limit_exceeded}} = Poller.run(fresh_activating.id, opts)
    failed_scan = Repo.one!(from(scan in AutomationScan, where: scan.rule_id == ^fresh_rule.id and scan.status == "failed"))
    assert failed_scan.match_count == 2
    assert Repo.aggregate(JiraObservation, :count, :id) == 1
    assert is_nil(Repo.get!(AutomationRule, fresh_rule.id).baseline_generation)

    assert {:ok, final_rule} = create_rule!(activating, %{source_id: "45"})
    assert {:ok, _final_activating} = Rules.activate(final_rule)

    assert {:error, %{kind: :scan_limit_exceeded}} =
             Poller.run(final_rule.id, poll_opts([page([jira_issue("1")])], monotonic_clock: over_time_after_page_clock()))

    assert Repo.aggregate(from(observation in JiraObservation, where: observation.rule_id == ^final_rule.id), :count, :id) == 1
    assert is_nil(Repo.get!(AutomationRule, final_rule.id).baseline_generation)
    assert Repo.aggregate(IntakeCase, :count, :id) == 0
  end

  test "missing analysis profile fails the activation without searching Jira", %{rule: rule} do
    assert {:ok, activating} = Rules.activate(rule)

    assert {:error, :analysis_profile_unavailable} =
             Poller.run(activating.id,
               request_fun: fn _request -> flunk("Jira search ran without an analysis profile") end,
               clock: fn -> ~U[2026-09-23 10:00:00Z] end
             )

    failed_scan = Repo.one!(from(scan in AutomationScan, where: scan.status == "failed"))
    assert failed_scan.error_code == "analysis_profile_unavailable"
    assert is_nil(Repo.get!(AutomationRule, rule.id).baseline_generation)
    refute Repo.get!(AutomationRule, rule.id).enabled
  end

  test "a config change during a paginated scan cancels the stale generation", %{rule: rule} do
    assert {:ok, activating} = Rules.activate(rule)
    first_page = page([jira_issue("1")], next_token: "second")
    second_page = page([])

    after_post = fn
      2 ->
        current = Repo.get!(AutomationRule, rule.id)
        assert {:ok, _updated} = Rules.patch(current, %{source_id: "99"})

      _other ->
        :ok
    end

    assert {:error, :stale_generation} =
             Poller.run(activating.id, poll_opts([first_page, second_page], after_post: after_post))

    updated_rule = Repo.get!(AutomationRule, rule.id)
    refute updated_rule.enabled
    assert updated_rule.source_id == "99"
    assert is_nil(updated_rule.baseline_generation)
    assert is_nil(updated_rule.last_success_at)
    cancelled = Repo.one!(from(scan in AutomationScan, where: scan.status == "cancelled"))
    assert cancelled.error_code == "stale_generation"
  end

  test "interval edits and pause/resume keep polling state; source changes start a fresh baseline", %{rule: rule} do
    assert {:ok, activating} = Rules.activate(rule)
    assert {:ok, baseline} = Poller.run(activating.id, poll_opts([page([])]))
    assert {:ok, first_poll} = Poller.run(rule.id, poll_opts([page([jira_issue("1")])]))
    assert first_poll.mode == "poll"
    assert Repo.aggregate(IntakeCase, :count, :id) == 1

    active = Repo.get!(AutomationRule, rule.id)
    old_generation = active.baseline_generation
    assert {:ok, changed_interval} = Rules.patch(active, %{interval_seconds: 600})
    assert changed_interval.enabled
    assert changed_interval.baseline_generation == old_generation

    assert {:ok, interval_scan} = Poller.run(rule.id, poll_opts([page([jira_issue("1")])]))
    assert interval_scan.mode == "poll"
    next_poll_at = Repo.get!(AutomationRule, rule.id).next_poll_at
    assert DateTime.diff(next_poll_at, ~U[2026-09-23 10:00:00Z], :second) == 600

    active = Repo.get!(AutomationRule, rule.id)
    assert {:ok, paused} = Rules.disable(active)
    refute paused.enabled
    assert paused.baseline_generation == old_generation
    assert {:ok, resumed} = Rules.activate(paused)
    assert resumed.enabled
    assert resumed.activation_status == "idle"
    assert {:ok, resumed_scan} = Poller.run(rule.id, poll_opts([page([jira_issue("1")])]))
    assert resumed_scan.mode == "poll"

    assert {:ok, filtered} = Rules.patch(Repo.get!(AutomationRule, rule.id), %{source_type: "filter"})
    refute filtered.enabled
    assert is_nil(filtered.baseline_generation)
    assert is_nil(filtered.baseline_complete_at)
    assert {:ok, filter_activating} = Rules.activate(filtered)
    assert filter_activating.activation_status == "activating"
    assert {:ok, new_baseline} = Poller.run(rule.id, poll_opts([page([jira_issue("1")])]))
    assert new_baseline.mode == "baseline"
    assert new_baseline.generation != baseline.generation
    assert Repo.aggregate(IntakeCase, :count, :id) == 1
  end

  test "an active lease prevents a second overlapping scan", %{rule: rule} do
    assert {:ok, activating} = Rules.activate(rule)
    parent = self()

    request_fun = fn request ->
      case Keyword.fetch!(request, :method) do
        :get ->
          {:ok, %{status: 200, body: %{"filter" => %{"id" => "77"}}}}

        :post ->
          send(parent, :search_started)
          Process.sleep(100)
          {:ok, %{status: 200, body: page([])}}
      end
    end

    poll = Task.async(fn -> Poller.run(activating.id, poll_opts([], request_fun: request_fun)) end)
    :ok = Sandbox.allow(Repo, self(), poll.pid)
    assert_receive :search_started
    assert {:error, :scan_in_progress} = Poller.run(activating.id, poll_opts([page([])]))
    assert {:ok, scan} = Task.await(poll, 1_000)
    assert scan.status == "succeeded"
  end

  @tag :lease_contract_test
  test "at most two scan leases are active across rules", %{rule: rule} do
    assert {:ok, first_rule} = Rules.activate(rule)
    assert {:ok, second_created} = create_rule!(rule, %{source_id: "#{System.unique_integer([:positive])}"})
    assert {:ok, third_created} = create_rule!(rule, %{source_id: "#{System.unique_integer([:positive])}"})
    assert {:ok, second_rule} = Rules.activate(second_created)
    assert {:ok, third_rule} = Rules.activate(third_created)
    parent = self()

    request_fun = fn rule_id, wait? ->
      fn request ->
        case Keyword.fetch!(request, :method) do
          :get ->
            {:ok, %{status: 200, body: %{"filter" => %{"id" => "77"}}}}

          :post when wait? ->
            send(parent, {:scan_claimed, rule_id, self()})

            receive do
              {:finish_claim, ^rule_id} -> {:ok, %{status: 200, body: page([])}}
            end

          :post ->
            {:ok, %{status: 200, body: page([])}}
        end
      end
    end

    first = Task.async(fn -> Poller.run(first_rule.id, poll_opts([], request_fun: request_fun.(first_rule.id, true))) end)
    :ok = Sandbox.allow(Repo, self(), first.pid)
    second = Task.async(fn -> Poller.run(second_rule.id, poll_opts([], request_fun: request_fun.(second_rule.id, true))) end)
    :ok = Sandbox.allow(Repo, self(), second.pid)

    assert_receive {:scan_claimed, first_id, first_worker}
    assert_receive {:scan_claimed, second_id, second_worker}
    assert MapSet.new([first_id, second_id]) == MapSet.new([first_rule.id, second_rule.id])

    assert {:error, :scan_capacity} = Poller.run(third_rule.id, poll_opts([], request_fun: request_fun.(third_rule.id, false)))

    # Claims may arrive in either order; release each worker with the rule it claimed.
    send(first_worker, {:finish_claim, first_id})
    send(second_worker, {:finish_claim, second_id})
    assert {:ok, first_scan} = Task.await(first, 5_000)
    assert {:ok, second_scan} = Task.await(second, 5_000)
    assert first_scan.status == "succeeded"
    assert second_scan.status == "succeeded"
  end

  @tag :lease_contract_test
  test "a locked rule is skipped instead of waiting behind another claim" do
    database = start_database_connection!()
    ids = raw_activating_rule!(database)

    try do
      Postgrex.query!(database, "BEGIN", [])
      Postgrex.query!(database, "SELECT id FROM automation_rules WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(ids.rule)])

      poll =
        Task.async(fn ->
          Poller.run(
            ids.rule,
            poll_opts([], request_fun: fn _request -> flunk("locked claim must not start a Jira request") end)
          )
        end)

      :ok = Sandbox.allow(Repo, self(), poll.pid)
      result = Task.yield(poll, 250)
      Postgrex.query!(database, "ROLLBACK", [])

      result = result || Task.await(poll, 1_000)
      assert {:ok, {:error, :scan_in_progress}} = result
    after
      cleanup_raw_rule!(database, ids.rule, ids.connection, ids.project)
      GenServer.stop(database)
    end
  end

  @tag :lease_contract_test
  test "scan lease lasts 120 seconds, renews after 30 seconds, and rejects the old owner", %{rule: rule} do
    base = ~U[2026-09-23 10:00:00Z]
    assert {:ok, activating} = Rules.activate(rule)
    {:ok, clock} = Agent.start_link(fn -> %{now: base, monotonic_ms: 0, page: 0} end)
    old_lease_token = Ecto.UUID.generate()
    generation = Ecto.UUID.generate()
    uuids = Agent.start_link(fn -> [generation, old_lease_token] end) |> elem(1)

    request_fun = fn request ->
      case Keyword.fetch!(request, :method) do
        :get ->
          claimed = Repo.get!(AutomationRule, activating.id)
          assert DateTime.diff(claimed.lease_until, base, :second) == 120
          {:ok, %{status: 200, body: %{"filter" => %{"id" => "77"}}}}

        :post ->
          page_number = Agent.get_and_update(clock, fn state -> {state.page + 1, %{state | page: state.page + 1}} end)

          if page_number == 1 do
            Agent.update(clock, fn state -> %{state | now: DateTime.add(base, 30, :second), monotonic_ms: 30_000} end)
            {:ok, %{status: 200, body: %{"issues" => [], "isLast" => false, "nextPageToken" => "page-2"}}}
          else
            renewed = Repo.get!(AutomationRule, activating.id)
            assert renewed.lease_until == DateTime.add(base, 150, :second) |> usec()
            {:ok, %{status: 200, body: page([])}}
          end
      end
    end

    assert {:ok, scan} =
             Poller.run(
               activating.id,
               poll_opts([],
                 request_fun: request_fun,
                 uuid_fun: fn -> Agent.get_and_update(uuids, fn [next | rest] -> {next, rest} end) end,
                 clock: fn -> Agent.get(clock, & &1.now) end,
                 monotonic_clock: fn -> Agent.get(clock, & &1.monotonic_ms) end
               )
             )

    assert {:error, :stale_generation} =
             Poller.heartbeat(activating.id, scan.id, old_lease_token, clock: fn -> DateTime.add(base, 31, :second) |> usec() end)
  end

  defp poll_opts(pages, opts \\ []) do
    [
      request_fun: request_fun(pages, Keyword.get(opts, :after_post, fn _index -> :ok end)),
      clock: fn -> ~U[2026-09-23 10:00:00Z] end,
      uuid_fun: &Ecto.UUID.generate/0,
      analysis_enabled: true,
      analysis_model: "synthetic-test-model",
      analysis_effort: "low"
    ]
    |> Keyword.merge(opts |> Keyword.delete(:after_post) |> Keyword.delete(:request_fun))
    |> then(fn options ->
      case Keyword.fetch(opts, :request_fun) do
        {:ok, fun} -> Keyword.put(options, :request_fun, fun)
        :error -> options
      end
    end)
  end

  defp usec(datetime), do: %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}

  defp start_database_connection! do
    opts = Repo.config() |> Keyword.take([:hostname, :port, :username, :password, :database])
    {:ok, connection} = Postgrex.start_link(opts)
    connection
  end

  defp raw_activating_rule!(database) do
    ids = %{project: Ecto.UUID.generate(), connection: Ecto.UUID.generate(), rule: Ecto.UUID.generate()}
    suffix = System.unique_integer([:positive])

    Postgrex.query!(
      database,
      "INSERT INTO projects (id, slug, forge_owner, forge_repo, forge_base_branch, config_version, config, inserted_at, updated_at) VALUES ($1, $2, 'example', 'harmony', 'main', 1, '{}', now(), now())",
      [Ecto.UUID.dump!(ids.project), "poller-lock-#{suffix}"]
    )

    Postgrex.query!(
      database,
      "INSERT INTO integration_connections (id, kind, name, settings, enabled, health, inserted_at, updated_at) VALUES ($1, 'jira_cloud', $2, $3::jsonb, TRUE, 'ok', now(), now())",
      [
        Ecto.UUID.dump!(ids.connection),
        "Poller lock #{suffix}",
        Jason.encode!(%{"site_url" => "https://poller-lock-#{suffix}.atlassian.net", "auth_mode" => "classic"})
      ]
    )

    Postgrex.query!(
      database,
      "INSERT INTO automation_rules (id, project_id, jira_connection_id, name, source_type, source_id, priority_ids, interval_seconds, initial_policy, linear_team_id, linear_project_id, linear_todo_state_id, linear_hold_label_id, email_recipients, sms_recipients, enabled, config_version, activation_status, lock_version, inserted_at, updated_at) VALUES ($1, $2, $3, 'Locked claim', 'board', '42', ARRAY['1'], 300, 'new_matches_only', 'team-id', 'project-id', 'todo-id', 'hold-id', ARRAY[]::text[], ARRAY[]::text[], FALSE, 1, 'activating', 1, now(), now())",
      [Ecto.UUID.dump!(ids.rule), Ecto.UUID.dump!(ids.project), Ecto.UUID.dump!(ids.connection)]
    )

    ids
  end

  defp cleanup_raw_rule!(database, rule_id, connection_id, project_id) do
    Postgrex.query!(database, "DELETE FROM automation_scans WHERE rule_id = $1", [Ecto.UUID.dump!(rule_id)])
    Postgrex.query!(database, "DELETE FROM automation_rules WHERE id = $1", [Ecto.UUID.dump!(rule_id)])
    Postgrex.query!(database, "DELETE FROM integration_connections WHERE id = $1", [Ecto.UUID.dump!(connection_id)])
    Postgrex.query!(database, "DELETE FROM projects WHERE id = $1", [Ecto.UUID.dump!(project_id)])
  end

  defp request_fun(search_pages, after_post) do
    {:ok, agent} = Agent.start_link(fn -> {search_pages, 0} end)

    fn request -> request_response(request, agent, after_post) end
  end

  defp request_response(request, agent, after_post) do
    case Keyword.fetch!(request, :method) do
      :get -> {:ok, %{status: 200, body: %{"filter" => %{"id" => "77"}}}}
      :post -> post_response(agent, after_post)
    end
  end

  defp post_response(agent, after_post) do
    {outcome, index} =
      Agent.get_and_update(agent, fn
        {[next | rest], count} -> {{next, count + 1}, {rest, count + 1}}
        {[], count} -> {{:error, :unexpected_jira_page, count + 1}, {[], count + 1}}
      end)

    after_post.(index)
    response_for(outcome)
  end

  defp response_for({:http, status, headers, body}), do: {:ok, %{status: status, headers: headers, body: body}}
  defp response_for({:http, status, body}), do: {:ok, %{status: status, body: body}}
  defp response_for({:error, reason, _index}), do: {:error, reason}
  defp response_for(body), do: {:ok, %{status: 200, body: body}}

  defp jira_issue(priority_id, key \\ "OPS-1") do
    priority_name = if priority_id == "1", do: "P1", else: "P2"

    %{
      "id" => "10001",
      "key" => key,
      "fields" => %{
        "summary" => "An old issue promoted after baseline",
        "description" => nil,
        "priority" => %{"id" => priority_id, "name" => priority_name},
        "status" => %{"id" => "1", "name" => "Open", "statusCategory" => %{"key" => "new"}},
        "created" => "2026-09-22T00:00:00.000+0000",
        "updated" => "2026-09-23T09:00:00.000+0000",
        "project" => %{"id" => "7", "key" => "OPS", "name" => "Operations"}
      }
    }
  end

  defp page(issues, opts \\ []) do
    case Keyword.get(opts, :next_token) do
      token when is_binary(token) -> %{"issues" => issues, "isLast" => false, "nextPageToken" => token}
      _ -> %{"issues" => issues, "isLast" => true}
    end
  end

  defp over_time_clock do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    fn ->
      Agent.get_and_update(agent, fn
        0 -> {0, 1}
        value -> {600_000, value + 1}
      end)
    end
  end

  defp over_time_after_page_clock do
    {:ok, agent} = Agent.start_link(fn -> [0, 0, 600_000] end)

    fn ->
      Agent.get_and_update(agent, fn
        [value | rest] -> {value, rest}
        [] -> {600_000, []}
      end)
    end
  end

  defp create_rule!(rule, overrides) do
    attrs =
      rule
      |> Map.from_struct()
      |> Map.take([
        :project_id,
        :jira_connection_id,
        :name,
        :source_type,
        :source_id,
        :priority_ids,
        :interval_seconds,
        :initial_policy,
        :linear_team_id,
        :linear_project_id,
        :linear_todo_state_id,
        :linear_hold_label_id,
        :email_connection_id,
        :email_recipients,
        :sms_connection_id,
        :sms_recipients
      ])
      |> Map.merge(overrides)
      |> Map.update!(:name, &"#{&1} copy")

    Rules.create(attrs)
  end

  defp rule! do
    project =
      %Project{}
      |> Project.changeset(%{
        slug: "intake-poller-#{System.unique_integer([:positive])}",
        forge_owner: "example",
        forge_repo: "harmony",
        forge_base_branch: "main",
        config: %{},
        config_version: 1,
        ui_color: "purple"
      })
      |> Repo.insert!()

    connection =
      %IntegrationConnection{}
      |> IntegrationConnection.changeset(%{
        kind: "jira_cloud",
        name: "Jira test",
        settings: %{
          "site_url" => "https://harmony.atlassian.net",
          "auth_mode" => "classic",
          "account_email" => "harmony@example.test"
        },
        secret: "synthetic-jira-token",
        enabled: true
      })
      |> Repo.insert!()

    {:ok, rule} =
      Rules.create(%{
        project_id: project.id,
        jira_connection_id: connection.id,
        name: "Promoted issue rule",
        source_type: "board",
        source_id: "42",
        priority_ids: ["1"],
        interval_seconds: 300,
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
  end
end
