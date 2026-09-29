defmodule SymphonyElixir.IntakeFaultInjectionTest do
  @moduledoc """
  Plan §10.2 fault-injection rows that no other intake test proves on its own.
  Every scenario runs on the test PostgreSQL with stubbed transports; restarts
  touch only processes started by the test.
  """

  use SymphonyElixir.TestSupport

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake.{Dispatcher, DispatcherRuntime, Outbox, Poller, Rules}
  alias SymphonyElixir.Repo
  alias SymphonyElixir.WorkRun

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

  @public_url "https://harmony.example.test"
  @smtp_hosts ["smtp.example.test"]

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), intake_effects_enabled: true, intake_public_url: @public_url)
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  describe "qualification and restart" do
    test "a crash before the qualification commit leaves no case or effect and the next poll accepts once" do
      rule = active_rule!()
      parent = self()
      issues = [jira_issue("10001", "OPS-1"), jira_issue("10002", "OPS-2")]

      # The first issue is fully written inside the page transaction; the crash
      # comes while the second issue is being qualified, before the commit.
      crashing_uuid = fn ->
        written_cases = Repo.aggregate(IntakeCase, :count, :id)

        if written_cases > 0 do
          send(parent, {:crashed_with_uncommitted, written_cases, Repo.aggregate(IntegrationDelivery, :count, :id)})
          raise "synthetic crash before commit"
        end

        Ecto.UUID.generate()
      end

      assert {:error, :unexpected_scan_failure} = Poller.run(rule.id, poll_opts([page(issues)], uuid_fun: crashing_uuid))
      assert_received {:crashed_with_uncommitted, 1, uncommitted_deliveries}
      assert uncommitted_deliveries > 0

      assert Repo.aggregate(IntakeCase, :count, :id) == 0
      assert Repo.aggregate(IntakeAnalysis, :count, :id) == 0
      assert Repo.aggregate(IntegrationDelivery, :count, :id) == 0
      assert Repo.aggregate(from(event in IntakeEvent, where: not is_nil(event.case_id)), :count, :id) == 0
      assert Repo.aggregate(JiraObservation, :count, :id) == 0
      failed_scan = Repo.one!(from(scan in AutomationScan, where: scan.mode == "poll"))
      assert failed_scan.status == "failed"
      assert failed_scan.error_code == "unexpected_scan_failure"

      assert {:ok, next_scan} = Poller.run(rule.id, poll_opts([page(issues)]))
      assert next_scan.accepted_count == 2
      assert {:ok, repeated_scan} = Poller.run(rule.id, poll_opts([page(issues)]))
      assert repeated_scan.accepted_count == 0

      cases = Repo.all(IntakeCase)
      assert cases |> Enum.map(& &1.jira_key) |> Enum.sort() == ["OPS-1", "OPS-2"]

      for intake_case <- cases do
        assert operations(intake_case) == ["analysis", "email", "linear_create", "sms"]
      end
    end

    test "a committed case and its deliveries survive a dispatcher restart before the first claim" do
      rule = active_rule!()
      assert {:ok, scan} = Poller.run(rule.id, poll_opts([page([jira_issue("10001", "OPS-1")])]))
      assert scan.accepted_count == 1
      intake_case = Repo.one!(IntakeCase)
      parent = self()

      adapter = fn claimed ->
        send(parent, {:adapter_called, claimed.id, claimed.operation, claimed.case_id})
        {:ok, %{provider_id: "restarted-#{claimed.operation}"}}
      end

      runtime_opts = [
        name: nil,
        tick_interval_ms: 0,
        enabled?: true,
        effects_enabled?: true,
        analysis_enabled?: true,
        adapter: adapter,
        result_observer: fn pool, result -> send(parent, {:dispatch_result, pool, result}) end
      ]

      supervisor =
        start_supervised!(%{
          id: :fault_injection_supervisor,
          type: :supervisor,
          start: {Supervisor, :start_link, [[{DispatcherRuntime, runtime_opts}], [strategy: :one_for_one]]}
        })

      original = runtime_pid(supervisor)
      monitor = Process.monitor(original)

      # The crash lands after the qualification commit and before any claim.
      Process.exit(original, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^original, :killed}
      restarted = await_restarted_runtime(supervisor, original)
      :ok = Sandbox.allow(Repo, self(), restarted)
      refute_received {:adapter_called, _id, _operation, _case_id}

      assert Repo.get!(IntakeCase, intake_case.id).analysis_status == "queued"
      pending = Repo.all(from(d in IntegrationDelivery, where: d.case_id == ^intake_case.id))
      assert Enum.all?(pending, &(&1.status == "pending" and &1.attempts == 0 and is_nil(&1.lease_token)))
      assert pending |> Enum.map(& &1.operation) |> Enum.sort() == ["analysis", "email", "linear_create", "sms"]

      assert {:ok, %{io: 4, analysis: 1}} = DispatcherRuntime.tick(restarted)
      await_results(5)

      # Analysis waits for a confirmed Linear issue, so it stays in the outbox.
      claimed = collect_adapter_calls()
      assert claimed |> Enum.map(&elem(&1, 1)) |> Enum.sort() == ["email", "linear_create", "sms"]
      assert Enum.all?(claimed, fn {_id, _operation, case_id} -> case_id == intake_case.id end)

      statuses = Repo.all(from(d in IntegrationDelivery, where: d.case_id == ^intake_case.id, select: {d.operation, d.status, d.attempts}))

      assert Enum.sort(statuses) == [
               {"analysis", "pending", 0},
               {"email", "succeeded", 1},
               {"linear_create", "succeeded", 1},
               {"sms", "succeeded", 1}
             ]
    end

    test "two pollers seeing one issue at once on separate PostgreSQL connections make one case and one delivery set" do
      fixture = Sandbox.unboxed_run(Repo, fn -> overlapping_rules_fixture!() end)
      on_exit(fn -> cleanup_committed_fixture!(fixture) end)
      parent = self()
      issue = jira_issue("20001", "OPS-20")

      tasks =
        Enum.map(fixture.rule_ids, fn rule_id ->
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo)

            Sandbox.unboxed_run(Repo, fn ->
              %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")

              request_fun = fn request ->
                case Keyword.fetch!(request, :method) do
                  :get ->
                    {:ok, %{status: 200, body: %{"filter" => %{"id" => "77"}}}}

                  :post ->
                    send(parent, {:poller_saw_issue, self(), backend_pid})
                    receive do: (:persist -> {:ok, %{status: 200, body: page([issue])}})
                end
              end

              Poller.run(rule_id, poll_opts([], request_fun: request_fun))
            end)
          end)
        end)

      pollers =
        Enum.map(tasks, fn _task ->
          assert_receive {:poller_saw_issue, poller, backend_pid}, 5_000
          {poller, backend_pid}
        end)

      assert pollers |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 2
      Enum.each(pollers, fn {poller, _backend_pid} -> send(poller, :persist) end)
      results = Enum.map(tasks, &Task.await(&1, 10_000))

      assert [{:ok, first}, {:ok, second}] = results
      assert Enum.sort([first.accepted_count, second.accepted_count]) == [0, 1]
      assert first.match_count == 1 and second.match_count == 1

      Sandbox.unboxed_run(Repo, fn ->
        [intake_case] = Repo.all(from(c in IntakeCase, where: c.jira_connection_id == ^fixture.jira_connection_id))
        assert operations(intake_case) == ["analysis", "email", "linear_create", "sms"]
        assert Repo.aggregate(from(a in IntakeAnalysis, where: a.case_id == ^intake_case.id), :count, :id) == 1

        linked_by_other_rule =
          Repo.all(
            from(event in IntakeEvent,
              where: event.case_id == ^intake_case.id and event.type == "already_linked",
              select: event.rule_id
            )
          )

        assert linked_by_other_rule == fixture.rule_ids -- [intake_case.rule_id]
      end)
    end
  end

  describe "effects after analysis" do
    test "a 403 on the Jira comment keeps the analysis result and a retry publishes without another model run" do
      intake_case = confirmed_case!()
      parent = self()

      assert {:ok, analysis_delivery} =
               Dispatcher.dispatch_one(dispatch_opts("analysis", analysis_opts: analysis_opts(parent, intake_case)))

      assert analysis_delivery.status == "succeeded"
      assert_received {:model_called, 1}
      stored_analysis = Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 1)
      assert stored_analysis.status == "succeeded"

      forbidden = jira_comment_request_fun(parent, {:ok, %Req.Response{status: 403, body: %{"message" => "forbidden"}}})
      assert {:failed, failed} = Dispatcher.dispatch_one(dispatch_opts("jira_comment", jira_comment_opts: [request_fun: forbidden]))
      assert failed.last_error_code == "jira_comment_permission_denied"
      assert_received {:jira_request, :post}

      after_forbidden = Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 1)
      assert after_forbidden.status == "succeeded"
      assert after_forbidden.result == stored_analysis.result
      assert after_forbidden.result["summary"] == "Synthetic fault-injection finding"

      assert {:ok, retrying} = Outbox.manual_retry(failed.id, now: now())
      assert retrying.status == "retry_wait"

      created = jira_comment_request_fun(parent, {:ok, %Req.Response{status: 201, body: %{"id" => "comment-after-403"}}})
      assert {:ok, published} = Dispatcher.dispatch_one(dispatch_opts("jira_comment", jira_comment_opts: [request_fun: created]))
      assert published.id == failed.id
      assert published.provider_id == "comment-after-403"

      assert :empty = Dispatcher.dispatch_one(dispatch_opts("analysis", analysis_opts: analysis_opts(parent, intake_case)))
      refute_received {:model_called, _count}
      assert Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 1).result == stored_analysis.result
      assert Repo.aggregate(from(a in IntakeAnalysis, where: a.case_id == ^intake_case.id), :count, :id) == 1
    end

    test "a definitively failed SMS channel does not stop e-mail or the analysis" do
      intake_case = confirmed_case!()
      parent = self()

      rejected_sms = fn request ->
        send(parent, {:sms_request, Map.new(request[:form]).idx})
        {:ok, %{status: 401, body: ""}}
      end

      assert {:failed, failed_sms} = Dispatcher.dispatch_one(dispatch_opts("sms", sms_opts: [request_fun: rejected_sms]))
      assert failed_sms.case_id == intake_case.id
      assert failed_sms.last_error_code == "sms_auth_failed"
      assert_received {:sms_request, _idx}

      smtp_fun = fn email, _options ->
        send(parent, {:email_sent, email.to})
        {:ok, "250 queued"}
      end

      assert {:ok, sent_email} = Dispatcher.dispatch_one(dispatch_opts("email", smtp_opts: smtp_opts(smtp_fun)))
      assert sent_email.case_id == intake_case.id
      assert_received {:email_sent, [{"", "oncall@example.test"}]}

      analysis_dispatch = dispatch_opts("analysis", analysis_opts: analysis_opts(parent, intake_case))
      assert {:ok, analysis} = Dispatcher.dispatch_one(analysis_dispatch)
      assert analysis.case_id == intake_case.id
      assert_received {:model_called, 1}

      assert Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 1).status == "succeeded"

      statuses = Repo.all(from(d in IntegrationDelivery, where: d.case_id == ^intake_case.id, select: {d.operation, d.status}))

      assert Enum.sort(statuses) == [
               {"analysis", "succeeded"},
               {"email", "succeeded"},
               {"jira_comment", "pending"},
               {"linear_create", "succeeded"},
               {"sms", "failed"}
             ]

      refute_received {:sms_request, _idx}
    end
  end

  describe "implementation dispatch" do
    test "an unreadable database during orchestrator dispatch keeps an imported Todo out of implementation" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        intake_effects_enabled: true,
        intake_public_url: @public_url
      )

      intake_case = confirmed_case!()
      project_id = intake_case.project_id

      # Label and marker are gone, so only the database mapping identifies the import.
      issue = %Issue{
        id: intake_case.linear_issue_id,
        identifier: "LIN-1",
        title: "Imported without markers",
        description: nil,
        state: "Todo",
        labels: []
      }

      parent = self()
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      work_run = WorkRun.from_linear_issue(issue, project_id: project_id)
      Application.put_env(:symphony_elixir, :work_source_fetchers, [fn -> {:ok, [work_run]} end])

      Application.put_env(:symphony_elixir, :agent_runner_fun, fn started_issue, _recipient, _opts ->
        send(parent, {:runner_started, started_issue.id})
        :ok
      end)

      # The orchestrator is not allowed into the test's sandbox connection, so each
      # of its Repo calls fails as if PostgreSQL were unreachable.
      name = Module.concat(__MODULE__, "UnreachableDatabaseOrchestrator#{System.unique_integer([:positive])}")
      {:ok, orchestrator} = Orchestrator.start_link(name: name, initial_poll_delay_ms: 60_000)
      on_exit(fn -> if Process.alive?(orchestrator), do: GenServer.stop(orchestrator, :normal) end)

      log =
        capture_log(fn ->
          send(orchestrator, :run_poll_cycle)
          refute_receive {:runner_started, _issue_id}, 500
          _state = :sys.get_state(orchestrator)
        end)

      assert log =~ "reason=:database_unavailable"
      assert Process.alive?(orchestrator)
      refute Map.has_key?(:sys.get_state(orchestrator).running, issue.id)
    end
  end

  defp operations(intake_case) do
    Repo.all(from(d in IntegrationDelivery, where: d.case_id == ^intake_case.id, select: d.operation, order_by: d.operation))
  end

  defp runtime_pid(supervisor) do
    [{DispatcherRuntime, pid, :worker, _modules}] = Supervisor.which_children(supervisor)
    pid
  end

  defp await_restarted_runtime(supervisor, original, attempts \\ 50) do
    case Supervisor.which_children(supervisor) do
      [{DispatcherRuntime, pid, :worker, _modules}] when is_pid(pid) and pid != original ->
        pid

      _children when attempts > 0 ->
        Process.sleep(10)
        await_restarted_runtime(supervisor, original, attempts - 1)
    end
  end

  defp await_results(count) do
    Enum.map(1..count, fn _index ->
      assert_receive {:dispatch_result, pool, result}, 5_000
      {pool, result}
    end)
  end

  defp collect_adapter_calls(acc \\ []) do
    receive do
      {:adapter_called, id, operation, case_id} -> collect_adapter_calls([{id, operation, case_id} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp analysis_opts(parent, intake_case) do
    counter = {:fault_injection_model_calls, intake_case.id}

    [
      workspace_root: System.tmp_dir!(),
      context_fun: fn _root, _case_id, _version, _project ->
        {:ok,
         %{
           path: Path.join(System.tmp_dir!(), "fault-injection-issue-only"),
           input_snapshot: %{"context_scope" => "issue_only", "context_reason" => "repository_not_configured"}
         }}
      end,
      model_fun: fn _path, _prompt, _issue, _opts ->
        calls = Process.get(counter, 0) + 1
        Process.put(counter, calls)
        send(parent, {:model_called, calls})
        {:ok, %{result: Jason.encode!(valid_result(intake_case.jira_key))}}
      end
    ]
  end

  defp valid_result(jira_key) do
    %{
      summary: "Synthetic fault-injection finding",
      facts: [%{text: "A synthetic Jira fact", source: "jira:#{jira_key}"}],
      hypotheses: [],
      missing_data: [],
      next_steps: ["Collect a synthetic log"],
      needs_input: false,
      context_scope: "issue_only"
    }
  end

  defp jira_comment_request_fun(parent, post_response) do
    fn request ->
      send(parent, {:jira_request, request[:method]})

      case request[:method] do
        :get ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"startAt" => 0, "maxResults" => 100, "total" => 0, "isLast" => true, "comments" => []}
           }}

        :post ->
          post_response
      end
    end
  end

  defp dispatch_opts(operation, overrides) do
    defaults = [now: now(), intake_enabled: true, effects_enabled: true, analysis_enabled: true, jitter: fn -> 0.0 end]
    defaults |> Keyword.put(:operation, operation) |> Keyword.merge(overrides)
  end

  defp smtp_opts(smtp_fun), do: [smtp_fun: smtp_fun, smtp_allowed_hosts: @smtp_hosts, cacerts: [:synthetic_ca]]

  # A case qualified by a real poll whose Linear issue is already confirmed.
  defp confirmed_case! do
    rule = active_rule!()
    assert {:ok, %{accepted_count: 1}} = Poller.run(rule.id, poll_opts([page([jira_issue("10001", "OPS-1")])]))
    intake_case = Repo.one!(IntakeCase)
    confirmed_at = now()

    Repo.update_all(from(d in IntegrationDelivery, where: d.case_id == ^intake_case.id and d.operation == "linear_create"),
      set: [status: "succeeded", attempts: 1, provider_id: intake_case.linear_issue_id, sent_at: confirmed_at]
    )

    intake_case
    |> IntakeCase.changeset(%{
      linear_identifier: "LIN-1",
      linear_url: "https://linear.app/harmony/issue/LIN-1",
      linear_state_name: "Todo",
      linear_confirmed_at: confirmed_at
    })
    |> Repo.update!()
  end

  defp active_rule!(overrides \\ %{}) do
    {:ok, rule} = Rules.create(Map.merge(rule_attrs(project!(), jira_connection!()), overrides))
    activate!(rule)
  end

  defp activate!(rule) do
    assert {:ok, activating} = Rules.activate(rule)
    assert {:ok, %{mode: "baseline", status: "succeeded"}} = Poller.run(activating.id, poll_opts([page([])]))
    Repo.get!(AutomationRule, rule.id)
  end

  defp rule_attrs(project, jira) do
    smtp = smtp_connection!()
    sms = sms_connection!()

    %{
      project_id: project.id,
      jira_connection_id: jira.id,
      name: "Fault injection rule #{System.unique_integer([:positive])}",
      source_type: "board",
      source_id: "#{System.unique_integer([:positive])}",
      priority_ids: ["1"],
      interval_seconds: 300,
      initial_policy: "new_matches_only",
      linear_team_id: "team-id",
      linear_project_id: "project-id",
      linear_todo_state_id: "todo-id",
      linear_hold_label_id: "hold-id",
      email_connection_id: smtp.id,
      email_recipients: ["oncall@example.test"],
      sms_connection_id: sms.id,
      sms_recipients: ["+48600100200"]
    }
  end

  defp overlapping_rules_fixture! do
    project = project!()
    jira = jira_connection!()

    [first, second] =
      Enum.map(1..2, fn _index ->
        {:ok, rule} = Rules.create(rule_attrs(project, jira))
        activate!(rule)
      end)

    connection_ids =
      [first, second]
      |> Enum.flat_map(&[&1.email_connection_id, &1.sms_connection_id])
      |> Kernel.++([jira.id])

    %{project_id: project.id, jira_connection_id: jira.id, connection_ids: connection_ids, rule_ids: [first.id, second.id]}
  end

  defp cleanup_committed_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      case_ids = Repo.all(from(c in IntakeCase, where: c.jira_connection_id == ^fixture.jira_connection_id, select: c.id))
      Repo.delete_all(from(e in IntakeEvent, where: e.case_id in ^case_ids or e.rule_id in ^fixture.rule_ids))
      Repo.delete_all(from(d in IntegrationDelivery, where: d.case_id in ^case_ids))
      Repo.delete_all(from(a in IntakeAnalysis, where: a.case_id in ^case_ids))
      Repo.delete_all(from(c in IntakeCase, where: c.id in ^case_ids))
      Repo.delete_all(from(o in JiraObservation, where: o.rule_id in ^fixture.rule_ids))
      Repo.delete_all(from(s in AutomationScan, where: s.rule_id in ^fixture.rule_ids))
      Repo.delete_all(from(r in AutomationRule, where: r.id in ^fixture.rule_ids))
      Repo.delete_all(from(c in IntegrationConnection, where: c.id in ^fixture.connection_ids))
      Repo.delete_all(from(p in Project, where: p.id == ^fixture.project_id))
    end)
  end

  defp project! do
    %Project{}
    |> Project.changeset(%{
      slug: "fault-injection-#{System.unique_integer([:positive])}",
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
    insert_connection!(%{
      kind: "jira_cloud",
      settings: %{
        "site_url" => "https://fault-injection-#{System.unique_integer([:positive])}.atlassian.net",
        "auth_mode" => "classic",
        "account_email" => "harmony@example.test"
      },
      secret: "synthetic-jira-token"
    })
  end

  defp smtp_connection! do
    insert_connection!(%{
      kind: "smtp",
      settings: %{
        "host" => "smtp.example.test",
        "port" => 587,
        "tls_mode" => "starttls",
        "username" => "synthetic-user",
        "from_email" => "alerts@example.test",
        "from_name" => "Harmony",
        "message_id_domain" => "example.test"
      },
      secret: "synthetic-smtp-password"
    })
  end

  defp sms_connection! do
    insert_connection!(%{kind: "smsapi", settings: %{"sender" => "Harmony"}, secret: "synthetic-smsapi-token"})
  end

  defp insert_connection!(attrs) do
    %IntegrationConnection{}
    |> IntegrationConnection.changeset(Map.merge(%{name: "#{attrs.kind} #{System.unique_integer([:positive])}", enabled: true}, attrs))
    |> Repo.insert!()
  end

  defp poll_opts(pages, overrides \\ []) do
    {:ok, agent} = Agent.start_link(fn -> pages end)

    [
      request_fun: fn request -> jira_response(request, agent) end,
      clock: fn -> ~U[2026-09-23 10:00:00Z] end,
      uuid_fun: &Ecto.UUID.generate/0,
      analysis_enabled: true,
      analysis_model: "synthetic-test-model",
      analysis_effort: "low"
    ]
    |> Keyword.merge(overrides)
  end

  defp jira_response(request, agent) do
    case Keyword.fetch!(request, :method) do
      :get -> {:ok, %{status: 200, body: %{"filter" => %{"id" => "77"}}}}
      :post -> {:ok, %{status: 200, body: Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)}}
    end
  end

  defp page(issues), do: %{"issues" => issues, "isLast" => true}

  defp jira_issue(id, key) do
    %{
      "id" => id,
      "key" => key,
      "fields" => %{
        "summary" => "Synthetic fault-injection issue #{key}",
        "description" => nil,
        "priority" => %{"id" => "1", "name" => "P1"},
        "status" => %{"id" => "1", "name" => "Open", "statusCategory" => %{"key" => "new"}},
        "created" => "2026-09-22T00:00:00.000+0000",
        "updated" => "2026-09-23T09:00:00.000+0000",
        "project" => %{"id" => "7", "key" => "OPS", "name" => "Operations"}
      }
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
