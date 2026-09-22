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

  defp request_fun(search_pages, after_post) do
    {:ok, agent} = Agent.start_link(fn -> {search_pages, 0} end)

    fn request ->
      case Keyword.fetch!(request, :method) do
        :get ->
          {:ok, %{status: 200, body: %{"filter" => %{"id" => "77"}}}}

        :post ->
          {outcome, index} =
            Agent.get_and_update(agent, fn
              {[next | rest], count} -> {{next, count + 1}, {rest, count + 1}}
              {[], count} -> {{:error, :unexpected_jira_page, count + 1}, {[], count + 1}}
            end)

          after_post.(index)

          case outcome do
            {:http, status, body} -> {:ok, %{status: status, body: body}}
            {:error, reason, _index} -> {:error, reason}
            body -> {:ok, %{status: 200, body: body}}
          end
      end
    end
  end

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
