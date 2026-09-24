defmodule SymphonyElixir.IntakeChannelTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ChannelTest
  import SymphonyElixir.CasesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake.{Actions, Connections, Dispatcher, Outbox, Poller, Rules}
  alias SymphonyElixir.{Repo, Storage}
  alias SymphonyElixir.Storage.{IntakeCase, IntegrationConnection}
  alias SymphonyElixirWeb.{IntakeChannel, IntakePubSub, UserSocket}

  @endpoint SymphonyElixirWeb.Endpoint
  @payload_keys [:case_ref, :changed_at, :project_id, :revision, :rule_id]
  @profile %{model: "synthetic-analysis-model", effort: "medium"}

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    write_workflow_file!(Workflow.workflow_file_path(),
      intake_enabled: true,
      intake_effects_enabled: true,
      intake_public_url: "https://harmony.example.test"
    )

    start_test_endpoint()
    :ok
  end

  describe "topic and payload" do
    test "the shared socket routes the new topic next to the unchanged observability topics" do
      assert {IntakeChannel, _opts} = UserSocket.__channel__("intake:workspace")
      assert {SymphonyElixirWeb.ObservabilityChannel, _opts} = UserSocket.__channel__("observability:dashboard")
      assert {SymphonyElixirWeb.RunChannel, _opts} = UserSocket.__channel__("observability:run:issue-1")
      assert IntakePubSub.topic() == "intake:workspace"
    end

    test "join replies without data and a broadcast carries only the whitelisted keys" do
      {:ok, reply, _socket} = join_workspace()
      assert reply == %{}

      project_id = Ecto.UUID.generate()
      rule_id = Ecto.UUID.generate()
      case_id = Ecto.UUID.generate()

      :ok =
        IntakePubSub.broadcast_changed(%{
          project_id: project_id,
          case_ref: "jira_" <> case_id,
          rule_id: rule_id,
          title: "Synthetic confidential title",
          secret: "synthetic-secret-value",
          recipient: "+19995550123"
        })

      assert_push("changed", payload)
      assert payload |> Map.keys() |> Enum.sort() == @payload_keys
      assert payload.project_id == project_id
      assert payload.case_ref == "jira_" <> case_id
      assert payload.rule_id == rule_id
      assert is_integer(payload.revision) and payload.revision > 0
      assert {:ok, _at, 0} = DateTime.from_iso8601(payload.changed_at)

      encoded = Jason.encode!(payload)
      refute encoded =~ "confidential"
      refute encoded =~ "synthetic-secret-value"
      refute encoded =~ "19995550123"
      refute_push("changed", _duplicate, 100)
    end

    test "values that are not identifiers never reach the topic" do
      {:ok, _reply, _socket} = join_workspace()

      :ok = IntakePubSub.broadcast_changed(%{project_id: "OPS-1 outage", case_ref: "jira_OPS-1 body", rule_id: 42})

      assert_push("changed", payload)
      assert payload |> Map.keys() |> Enum.sort() == @payload_keys
      assert %{project_id: nil, case_ref: nil, rule_id: nil} = payload
    end

    test "revisions grow between events" do
      {:ok, _reply, _socket} = join_workspace()

      :ok = IntakePubSub.broadcast_changed(%{project_id: Ecto.UUID.generate()})
      :ok = IntakePubSub.broadcast_changed(%{project_id: Ecto.UUID.generate()})

      assert_push("changed", %{revision: first})
      assert_push("changed", %{revision: second})
      assert second > first
    end

    test "intake events do not leak onto the observability topics" do
      :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe()
      :ok = SymphonyElixirWeb.ObservabilityRunPubSub.subscribe("issue-1")

      :ok = IntakePubSub.broadcast_changed(%{project_id: Ecto.UUID.generate()})

      refute_receive :observability_updated, 100
      refute_receive {:run_status_changed, _payload}, 10
    end
  end

  describe "events follow the commit" do
    test "a tracked change is broadcast only after its transaction commits" do
      :ok = IntakePubSub.subscribe()
      case_id = Ecto.UUID.generate()
      project_id = Ecto.UUID.generate()

      assert {:ok, :committed} =
               IntakePubSub.transaction(fn ->
                 :ok = IntakePubSub.track(%{project_id: project_id, case_ref: "jira_" <> case_id})
                 refute_received {:intake_changed, _payload}
                 :committed
               end)

      assert_receive {:intake_changed, %{project_id: ^project_id, case_ref: case_ref}}
      assert case_ref == "jira_" <> case_id
    end

    test "a rolled back transaction with a real write broadcasts nothing" do
      :ok = IntakePubSub.subscribe()
      scope = scope!()
      intake_case = intake_case!(scope)

      assert {:error, :synthetic_rollback} =
               IntakePubSub.transaction(fn ->
                 intake_case |> IntakeCase.changeset(%{lock_version: 7}) |> Repo.update!()
                 :ok = IntakePubSub.track_case(intake_case)
                 Repo.rollback(:synthetic_rollback)
               end)

      assert Repo.get!(IntakeCase, intake_case.id).lock_version == 1
      refute_receive {:intake_changed, _payload}, 100
    end

    test "a crash inside the transaction broadcasts nothing and leaves no pending event behind" do
      :ok = IntakePubSub.subscribe()

      assert_raise RuntimeError, fn ->
        IntakePubSub.transaction(fn ->
          :ok = IntakePubSub.track(%{project_id: Ecto.UUID.generate()})
          raise "synthetic crash"
        end)
      end

      refute_receive {:intake_changed, _payload}, 100

      project_id = Ecto.UUID.generate()
      assert {:ok, :ok} = IntakePubSub.transaction(fn -> IntakePubSub.track(%{project_id: project_id}) end)
      assert_receive {:intake_changed, %{project_id: ^project_id}}
      refute_receive {:intake_changed, _payload}, 100
    end

    test "a notification inside an untracked open transaction is dropped, not sent early" do
      :ok = IntakePubSub.subscribe()

      log =
        capture_log(fn ->
          project_id = Ecto.UUID.generate()
          assert {:ok, :ok} = Repo.transaction(fn -> IntakePubSub.broadcast_changed(%{project_id: project_id}) end)
        end)

      refute_receive {:intake_changed, _payload}, 100
      assert log =~ "intake change notification skipped inside an open transaction"
    end

    test "an operator action pushes the case reference after commit, without case content" do
      {:ok, _reply, _socket} = join_workspace()
      scope = scope!()
      intake_case = ready_case!(scope)

      assert {:ok, acknowledged} = Actions.acknowledge(intake_case.id, intake_case.lock_version)
      assert acknowledged.acknowledged_at

      assert_push("changed", payload)
      assert payload |> Map.keys() |> Enum.sort() == @payload_keys
      assert payload.case_ref == "jira_" <> intake_case.id
      assert payload.project_id == scope.project.id
      assert payload.rule_id == scope.rule.id

      encoded = Jason.encode!(payload)
      refute encoded =~ intake_case.title
      refute encoded =~ intake_case.jira_key
      refute encoded =~ intake_case.description_text
      refute encoded =~ "oncall@example.test"
      refute_push("changed", _another, 100)
    end

    test "an operator action whose transaction rolls back after writing pushes nothing" do
      {:ok, _reply, _socket} = join_workspace()
      scope = scope!()
      intake_case = intake_case!(scope, %{analysis_status: "ready"})
      # The reanalysis of version 2 collides with this existing delivery key after
      # the case row was already updated, so PostgreSQL aborts the transaction.
      delivery!(intake_case, "analysis", "pending", %{version: 2})

      assert {:error, :action_unavailable} =
               Actions.reanalyze(intake_case.id, intake_case.lock_version, true, analysis_profile: @profile)

      reloaded = Repo.get!(IntakeCase, intake_case.id)
      assert reloaded.lock_version == intake_case.lock_version
      assert reloaded.analysis_version == 1
      refute_push("changed", _payload, 200)
    end

    test "each committed outbox transition pushes its case" do
      {:ok, _reply, _socket} = join_workspace()
      scope = scope!()
      intake_case = intake_case!(scope)
      delivery!(intake_case, "linear_create", "pending")

      assert {:ok, completed} =
               Dispatcher.dispatch_one(fn _delivery -> {:ok, %{provider_id: "synthetic-linear"}} end,
                 now: DateTime.utc_now(),
                 operation: "linear_create",
                 intake_enabled: true,
                 effects_enabled: true,
                 analysis_enabled: true,
                 jitter: fn -> 0.0 end
               )

      assert completed.status == "succeeded"
      case_ref = "jira_" <> intake_case.id

      # One event for the committed claim, one for the committed completion.
      assert_push("changed", %{case_ref: ^case_ref})
      assert_push("changed", %{case_ref: ^case_ref})
    end

    test "a manual delivery retry pushes its case" do
      {:ok, _reply, _socket} = join_workspace()
      scope = scope!()
      intake_case = intake_case!(scope)
      failed = delivery!(intake_case, "linear_create", "failed")

      assert {:ok, retried} = Outbox.manual_retry(failed.id)
      assert retried.status == "retry_wait"

      case_ref = "jira_" <> intake_case.id
      assert_push("changed", %{case_ref: ^case_ref})
    end

    test "a test-send without a case pushes nothing" do
      {:ok, _reply, _socket} = join_workspace()

      connection =
        %IntegrationConnection{}
        |> IntegrationConnection.changeset(%{
          kind: "smtp",
          name: "SMTP #{System.unique_integer([:positive])}",
          settings: %{"host" => "localhost", "port" => 2525, "from_email" => "harmony@example.test"},
          secret: "synthetic-smtp-secret",
          enabled: true
        })
        |> Repo.insert!()

      assert {:ok, _delivery} = Outbox.enqueue_test_send(connection, "ops@example.test", Ecto.UUID.generate())
      refute_push("changed", _payload, 100)
    end

    test "a scan that qualifies an issue pushes the rule and the new case" do
      {:ok, _reply, _socket} = join_workspace()
      scope = scope!()
      rule = scope.rule
      {:ok, include_rule} = Rules.patch(rule, %{initial_policy: "include_existing"})
      {:ok, activating} = Rules.activate(include_rule)

      assert {:ok, scan} = Poller.run(activating.id, poll_opts([jira_issue("1")]))
      assert scan.accepted_count == 1

      intake_case = Repo.get_by!(IntakeCase, rule_id: rule.id)
      case_ref = "jira_" <> intake_case.id
      rule_id = rule.id
      project_id = scope.project.id

      pushes = collect_pushes()
      assert %{case_ref: ^case_ref, rule_id: ^rule_id, project_id: ^project_id} = Enum.find(pushes, &(&1.case_ref == case_ref))
      assert Enum.any?(pushes, &match?(%{case_ref: nil, rule_id: ^rule_id, project_id: ^project_id}, &1))
      refute Jason.encode!(pushes) =~ "An issue qualified by the scan"
    end

    test "a versioned rule change pushes the rule; a stale version pushes nothing" do
      {:ok, _reply, _socket} = join_workspace()
      scope = scope!()
      rule = Repo.reload!(scope.rule)

      assert {:error, :stale_version} = Rules.pause_versioned(rule.id, rule.config_version + 1)
      refute_push("changed", _payload, 100)

      assert {:ok, _paused} = Rules.pause_versioned(rule.id, rule.config_version)
      rule_id = rule.id
      project_id = scope.project.id
      assert_push("changed", %{rule_id: ^rule_id, project_id: ^project_id, case_ref: nil})
    end

    test "a connection edit pushes a workspace event without the secret" do
      {:ok, _reply, _socket} = join_workspace()
      scope = scope!()
      connection = scope.jira

      assert {:ok, _updated} =
               Connections.update_input(connection.id, connection.lock_version, %{"secret" => "synthetic-new-jira-token"})

      assert_push("changed", payload)
      assert %{project_id: nil, case_ref: nil, rule_id: nil} = payload
      refute Jason.encode!(payload) =~ "synthetic-new-jira-token"
    end

    test "clearing a secret also pushes every rule it disabled" do
      {:ok, _reply, _socket} = join_workspace()
      scope = scope!()
      scope.rule |> Ecto.Changeset.change(%{enabled: true}) |> Repo.update!()

      assert {:ok, _updated} =
               Connections.update_input(scope.jira.id, scope.jira.lock_version, %{"clear_secret" => true})

      rule_id = scope.rule.id
      pushes = collect_pushes()
      assert Enum.any?(pushes, &match?(%{project_id: nil, case_ref: nil, rule_id: nil}, &1))
      assert Enum.any?(pushes, &match?(%{rule_id: ^rule_id}, &1))
    end

    test "agent work pushes its run reference only when the run is new or changes status" do
      {:ok, _reply, _socket} = join_workspace()
      project = project!()
      attrs = %{project_id: project.id, type: "implementation", status: "queued", dedupe_key: "synthetic-run", agent_backend: "codex", payload: %{}}

      assert {:ok, run} = Storage.upsert_work_run(attrs)
      case_ref = "run_" <> run.id
      project_id = project.id
      assert_push("changed", %{case_ref: ^case_ref, project_id: ^project_id, rule_id: nil})

      assert {:ok, _same} = Storage.upsert_work_run(attrs)
      refute_push("changed", _payload, 100)

      assert {:ok, _running} = Storage.upsert_work_run(%{attrs | status: "running"})
      assert_push("changed", %{case_ref: ^case_ref})

      assert :ok = Storage.update_work_run_status(run.id, "stopped")
      assert_push("changed", %{case_ref: ^case_ref})
    end
  end

  defp join_workspace do
    UserSocket
    |> socket("user_socket", %{})
    |> subscribe_and_join(IntakeChannel, "intake:workspace")
  end

  defp collect_pushes(acc \\ []) do
    receive do
      %Phoenix.Socket.Message{event: "changed", payload: payload} -> collect_pushes([payload | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp poll_opts(issues) do
    {:ok, agent} = Agent.start_link(fn -> [%{"issues" => issues, "isLast" => true}] end)

    [
      request_fun: fn request ->
        case Keyword.fetch!(request, :method) do
          :get ->
            {:ok, %{status: 200, body: %{"filter" => %{"id" => "77"}}}}

          :post ->
            body = Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
            {:ok, %{status: 200, body: body}}
        end
      end,
      clock: fn -> ~U[2026-09-23 10:00:00Z] end,
      uuid_fun: &Ecto.UUID.generate/0,
      analysis_enabled: true,
      analysis_model: "synthetic-test-model",
      analysis_effort: "low"
    ]
  end

  defp jira_issue(priority_id) do
    %{
      "id" => "10001",
      "key" => "OPS-1",
      "fields" => %{
        "summary" => "An issue qualified by the scan",
        "description" => nil,
        "priority" => %{"id" => priority_id, "name" => "P1"},
        "status" => %{"id" => "1", "name" => "Open", "statusCategory" => %{"key" => "new"}},
        "created" => "2026-09-22T00:00:00.000+0000",
        "updated" => "2026-09-23T09:00:00.000+0000",
        "project" => %{"id" => "7", "key" => "OPS", "name" => "Operations"}
      }
    }
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
