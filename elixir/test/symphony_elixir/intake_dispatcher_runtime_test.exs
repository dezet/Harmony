defmodule SymphonyElixir.IntakeDispatcherRuntimeTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake
  alias SymphonyElixir.Intake.{Dispatcher, DispatcherRuntime, Scheduler}
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{AutomationRule, IntakeCase, IntegrationConnection, IntegrationDelivery, Project}

  @public_url "https://harmony.example.test"

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  describe "supervision" do
    test "the dispatcher child starts only with the runtime intake switch" do
      refute Intake.enabled?()
      refute Process.whereis(DispatcherRuntime)
      assert SymphonyElixir.Application.intake_children(Intake.settings()) == []

      write_workflow_file!(Workflow.workflow_file_path(),
        intake_enabled: true,
        intake_effects_enabled: false,
        intake_public_url: @public_url
      )

      assert SymphonyElixir.Application.intake_children(Intake.settings()) == [Scheduler, DispatcherRuntime]

      log =
        capture_log(fn ->
          assert SymphonyElixir.Application.intake_children({:error, :invalid_workflow}) == []
        end)

      assert log =~ "error_code=invalid_intake_settings"
    end
  end

  describe "dispatch ticks" do
    test "a tick performs an overdue effect through the injected adapter" do
      delivery = delivery!("email")
      parent = self()

      adapter = fn claimed ->
        send(parent, {:adapter_called, claimed.id, claimed.operation, claimed.status})
        {:ok, %{provider_id: "accepted-1"}}
      end

      runtime = start_runtime!(adapter: adapter)

      assert {:ok, %{io: 4, analysis: 1}} = DispatcherRuntime.tick(runtime)
      delivery_id = delivery.id
      assert_receive {:adapter_called, ^delivery_id, "email", "running"}
      results = await_results(5)
      assert Enum.any?(results, &match?({:io, {:ok, %IntegrationDelivery{id: ^delivery_id, status: "succeeded"}}}, &1))
      assert Enum.count(results, &match?({_pool, :empty}, &1)) == 4
      assert Repo.get!(IntegrationDelivery, delivery_id).provider_id == "accepted-1"
    end

    test "the periodic tick dispatches without an explicit call" do
      delivery = delivery!("sms")
      parent = self()

      runtime =
        start_runtime!(
          tick_interval_ms: 5,
          adapter: fn claimed ->
            send(parent, {:adapter_called, claimed.id})
            {:ok, %{provider_id: "sms-accepted"}}
          end
        )

      delivery_id = delivery.id
      assert_receive {:adapter_called, ^delivery_id}, 1_000
      assert_receive {:dispatch_result, :io, {:ok, %IntegrationDelivery{id: ^delivery_id}}}, 1_000
      assert Process.alive?(runtime)
    end

    test "at most four I/O effects and one analysis run at the same time" do
      email_ids = MapSet.new(Enum.map(1..6, fn _index -> delivery!("email").id end))
      analysis_ids = MapSet.new(Enum.map(1..2, fn _index -> confirmed_analysis_delivery!().id end))
      parent = self()

      adapter = fn claimed ->
        send(parent, {:adapter_started, claimed.operation, claimed.id, self()})

        receive do
          :release -> {:ok, %{provider_id: "released-#{claimed.id}"}}
        end
      end

      # Outbox limits are raised so that only the runtime's own pools cap the work.
      runtime = start_runtime!(adapter: adapter, dispatch_opts: [io_limit: 10, analysis_limit: 10])

      assert {:ok, %{io: 4, analysis: 1}} = DispatcherRuntime.tick(runtime)

      io_workers =
        Enum.map(1..4, fn _index ->
          assert_receive {:adapter_started, "email", id, worker}
          assert MapSet.member?(email_ids, id)
          worker
        end)

      assert_receive {:adapter_started, "analysis", analysis_id, analysis_worker}
      assert MapSet.member?(analysis_ids, analysis_id)
      refute_receive {:adapter_started, _operation, _id, _worker}, 200

      assert {:ok, %{io: 0, analysis: 0}} = DispatcherRuntime.tick(runtime)
      refute_receive {:adapter_started, _operation, _id, _worker}, 100

      [first_worker | other_workers] = io_workers
      send(first_worker, :release)
      assert_receive {:dispatch_result, :io, {:ok, %IntegrationDelivery{status: "succeeded"}}}

      assert {:ok, %{io: 1, analysis: 0}} = DispatcherRuntime.tick(runtime)
      assert_receive {:adapter_started, "email", fifth_id, fifth_worker}
      assert MapSet.member?(email_ids, fifth_id)
      refute_receive {:adapter_started, _operation, _id, _worker}, 100

      Enum.each([fifth_worker, analysis_worker | other_workers], &send(&1, :release))
      results = await_results(5)
      assert Enum.count(results, &match?({:io, {:ok, %IntegrationDelivery{status: "succeeded"}}}, &1)) == 4
      # The fixture has no intake_analyses row, so only the pool is asserted here.
      assert Enum.count(results, &match?({:analysis, _result}, &1)) == 1
    end

    test "disabled effects or intake switches make no adapter calls" do
      email = delivery!("email")
      analysis = confirmed_analysis_delivery!()
      parent = self()
      adapter = fn claimed -> send(parent, {:adapter_called, claimed.id}) && {:ok, %{}} end

      effects_off = start_runtime!(adapter: adapter, effects_enabled?: false)
      assert {:ok, %{io: 0, analysis: 0}} = DispatcherRuntime.tick(effects_off)

      intake_off = start_runtime!(adapter: adapter, enabled?: false)
      assert {:ok, %{io: 0, analysis: 0}} = DispatcherRuntime.tick(intake_off)

      unreadable = start_runtime!(adapter: adapter, enabled?: fn -> raise ArgumentError, "invalid WORKFLOW.md" end)

      log = capture_log(fn -> assert {:ok, %{io: 0, analysis: 0}} = DispatcherRuntime.tick(unreadable) end)
      assert log =~ "error_code=invalid_intake_settings"
      assert Process.alive?(unreadable)

      refute_receive {:adapter_called, _id}, 100
      assert Repo.get!(IntegrationDelivery, email.id).status == "pending"
      assert Repo.get!(IntegrationDelivery, analysis.id).status == "pending"
    end

    test "intake and effects disabled in the runtime config after a restart start no new effects" do
      write_workflow_file!(Workflow.workflow_file_path(),
        intake_enabled: true,
        intake_effects_enabled: false,
        intake_public_url: @public_url
      )

      email = delivery!("email")
      parent = self()

      restarted =
        start_runtime!(
          [adapter: fn claimed -> send(parent, {:adapter_called, claimed.id}) && {:ok, %{}} end],
          [:enabled?, :effects_enabled?, :analysis_enabled?]
        )

      assert {:ok, %{io: 0, analysis: 0}} = DispatcherRuntime.tick(restarted)
      refute_receive {:adapter_called, _id}, 100
      assert Repo.get!(IntegrationDelivery, email.id).status == "pending"
    end

    test "disabled analysis keeps analysis pending while I/O effects continue" do
      email = delivery!("email")
      analysis = confirmed_analysis_delivery!()
      parent = self()

      runtime =
        start_runtime!(
          analysis_enabled?: false,
          adapter: fn claimed ->
            send(parent, {:adapter_called, claimed.id, claimed.operation})
            {:ok, %{provider_id: "accepted"}}
          end
        )

      assert {:ok, %{io: 4, analysis: 0}} = DispatcherRuntime.tick(runtime)
      email_id = email.id
      assert_receive {:adapter_called, ^email_id, "email"}
      assert [_ | _] = await_results(4)
      refute_receive {:adapter_called, _id, "analysis"}, 100
      assert Repo.get!(IntegrationDelivery, analysis.id).status == "pending"
    end
  end

  describe "failure isolation" do
    test "an adapter exception does not stop the runtime or the other effects" do
      failing = delivery!("email")
      healthy = delivery!("sms")
      failing_id = failing.id
      healthy_id = healthy.id

      adapter = fn
        %IntegrationDelivery{id: ^failing_id} -> raise "adapter exploded token=secret-value"
        %IntegrationDelivery{id: ^healthy_id} -> {:ok, %{provider_id: "sms-ok"}}
      end

      runtime = start_runtime!(adapter: adapter)

      log =
        capture_log(fn ->
          assert {:ok, %{io: 4, analysis: 1}} = DispatcherRuntime.tick(runtime)
          results = await_results(5)
          assert Enum.any?(results, &match?({:io, {:ok, %IntegrationDelivery{id: ^healthy_id, status: "succeeded"}}}, &1))
          assert {:io, {:error, :dispatch_failed}} in results
        end)

      assert log =~ "error_code=dispatch_failed"
      refute log =~ "secret-value"
      assert Process.alive?(runtime)
      assert {:ok, %{io: 4, analysis: 1}} = DispatcherRuntime.tick(runtime)
      assert Enum.all?(await_results(5), &match?({_pool, :empty}, &1))
    end

    test "a killed worker releases its slot without stopping the runtime" do
      parent = self()

      dispatch_fun = fn _opts ->
        send(parent, {:worker, self()})
        receive do: (:never -> :empty)
      end

      runtime = start_runtime!(dispatch_fun: dispatch_fun)

      log =
        capture_log(fn ->
          assert {:ok, %{io: 4, analysis: 1}} = DispatcherRuntime.tick(runtime)
          workers = Enum.map(1..5, fn _index -> assert_receive({:worker, worker}) && worker end)
          Enum.each(workers, &Process.exit(&1, :kill))

          assert Enum.all?(await_results(5), &match?({_pool, {:error, :killed}}, &1))
        end)

      assert log =~ "error_code=killed"
      assert Process.alive?(runtime)

      capture_log(fn ->
        assert {:ok, %{io: 4, analysis: 1}} = DispatcherRuntime.tick(runtime)
        Enum.each(1..5, fn _index -> assert_receive({:worker, worker}) && Process.exit(worker, :kill) end)
        assert length(await_results(5)) == 5
      end)
    end

    test "an unavailable database during dispatch keeps no in-memory work and recovers from the outbox" do
      delivery = delivery!("email")
      parent = self()
      {:ok, database} = Agent.start_link(fn -> :down end)

      dispatch_fun = fn opts ->
        case Agent.get(database, & &1) do
          :down -> raise DBConnection.ConnectionError, "connection refused password=secret-value"
          :up -> Dispatcher.dispatch_one(adapter_sending(parent), opts)
        end
      end

      runtime = start_runtime!(dispatch_fun: dispatch_fun)

      log =
        capture_log(fn ->
          assert {:ok, %{io: 4, analysis: 1}} = DispatcherRuntime.tick(runtime)

          assert Enum.all?(await_results(5), &match?({_pool, {:error, :dispatch_failed}}, &1))
        end)

      assert log =~ "error_code=dispatch_failed"
      refute log =~ "secret-value"
      assert Process.alive?(runtime)
      assert Repo.get!(IntegrationDelivery, delivery.id).status == "pending"

      Agent.update(database, fn _state -> :up end)
      assert {:ok, %{io: 4, analysis: 1}} = DispatcherRuntime.tick(runtime)
      delivery_id = delivery.id
      assert_receive {:adapter_called, ^delivery_id}
      assert Enum.any?(await_results(5), &match?({:io, {:ok, %IntegrationDelivery{id: ^delivery_id, status: "succeeded"}}}, &1))
    end
  end

  # Keys listed in `config_keys` are left to the runtime defaults, which read Config.
  defp start_runtime!(overrides, config_keys \\ []) do
    parent = self()

    defaults = [
      name: nil,
      tick_interval_ms: 0,
      enabled?: true,
      effects_enabled?: true,
      analysis_enabled?: true,
      result_observer: fn pool, result -> send(parent, {:dispatch_result, pool, result}) end
    ]

    opts = defaults |> Keyword.merge(overrides) |> Keyword.drop(config_keys)

    {:ok, runtime} = DispatcherRuntime.start_link(opts)
    :ok = Sandbox.allow(Repo, self(), runtime)
    on_exit(fn -> if Process.alive?(runtime), do: GenServer.stop(runtime) end)
    runtime
  end

  defp await_results(count) do
    Enum.map(1..count, fn _index ->
      assert_receive {:dispatch_result, pool, result}, 5_000
      {pool, result}
    end)
  end

  defp adapter_sending(parent) do
    fn claimed ->
      send(parent, {:adapter_called, claimed.id})
      {:ok, %{provider_id: "recovered"}}
    end
  end

  defp delivery!(operation, attrs \\ []) do
    connection_kind =
      case operation do
        "email" -> "smtp"
        "sms" -> "smsapi"
        _operation -> nil
      end

    connection_id =
      if connection_kind do
        connection =
          %IntegrationConnection{}
          |> IntegrationConnection.changeset(%{
            kind: connection_kind,
            name: "#{operation} #{System.unique_integer([:positive])}",
            settings:
              case connection_kind do
                "smtp" -> %{host: "smtp.example.test"}
                "smsapi" -> %{sender: "Harmony"}
              end,
            enabled: true
          })
          |> Repo.insert!()

        connection.id
      end

    defaults = %{
      operation: operation,
      connection_id: connection_id,
      dedupe_key: "dispatcher-runtime:#{Ecto.UUID.generate()}",
      payload: %{},
      status: "pending",
      attempts: 0,
      next_attempt_at: DateTime.add(now(), -1, :second)
    }

    %IntegrationDelivery{}
    |> IntegrationDelivery.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp confirmed_analysis_delivery! do
    unique = System.unique_integer([:positive])

    connection =
      %IntegrationConnection{}
      |> IntegrationConnection.changeset(%{
        kind: "jira_cloud",
        name: "Runtime analysis Jira #{unique}",
        settings: %{site_url: "https://runtime-analysis-#{unique}.atlassian.net"},
        enabled: true
      })
      |> Repo.insert!()

    project =
      %Project{}
      |> Project.changeset(%{
        slug: "runtime-analysis-#{unique}",
        forge_owner: "example",
        forge_repo: "harmony",
        forge_base_branch: "main",
        config: %{},
        config_version: 1
      })
      |> Repo.insert!()

    rule =
      %AutomationRule{}
      |> AutomationRule.changeset(%{
        project_id: project.id,
        jira_connection_id: connection.id,
        name: "Runtime analysis rule",
        source_type: "board",
        source_id: "42",
        priority_ids: ["1"],
        interval_seconds: 300,
        initial_policy: "new_matches_only",
        linear_team_id: "team",
        linear_project_id: "project",
        linear_todo_state_id: "todo",
        linear_hold_label_id: "hold",
        email_recipients: [],
        sms_recipients: []
      })
      |> Repo.insert!()

    timestamp = now()

    intake_case =
      %IntakeCase{}
      |> IntakeCase.changeset(%{
        project_id: project.id,
        rule_id: rule.id,
        jira_connection_id: connection.id,
        jira_issue_id: Ecto.UUID.generate(),
        jira_key: "OPS-#{unique}",
        jira_url: "https://runtime-analysis-#{unique}.atlassian.net/browse/OPS-#{unique}",
        title: "Runtime analysis case",
        description_text: "",
        priority_id: "1",
        priority_name: "Highest",
        jira_updated_at: timestamp,
        detected_at: timestamp,
        rule_snapshot: %{},
        linear_issue_id: Ecto.UUID.generate(),
        linear_confirmed_at: timestamp,
        analysis_version: 1,
        analysis_status: "queued",
        lock_version: 1
      })
      |> Repo.insert!()

    delivery!("analysis", case_id: intake_case.id)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
