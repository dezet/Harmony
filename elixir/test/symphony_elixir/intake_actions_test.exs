defmodule SymphonyElixir.IntakeActionsTest do
  use SymphonyElixir.TestSupport

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake.{Actions, ExecutionGate}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Repo

  alias SymphonyElixir.Storage.{
    AutomationRule,
    IntakeAnalysis,
    IntakeCase,
    IntakeEvent,
    IntegrationConnection,
    IntegrationDelivery,
    Project
  }

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "acknowledging a case does not approve repair or refresh implementation" do
    {_project, _rule, _connection, intake_case} = case_fixture!()
    parent = self()
    refresh_fun = fn -> send(parent, :implementation_refresh_requested) end
    issue = managed_issue(intake_case)

    assert {:error, :analysis_only} = ExecutionGate.authorize_implementation(issue, intake_case.project_id)

    assert {:ok, acknowledged} =
             Actions.acknowledge(intake_case.id, intake_case.lock_version,
               clock: &now/0,
               refresh_fun: refresh_fun
             )

    assert acknowledged.acknowledged_at
    assert is_nil(acknowledged.repair_approved_at)
    assert is_nil(acknowledged.repair_approved_version)
    assert acknowledged.lock_version == intake_case.lock_version + 1
    assert {:error, :analysis_only} = ExecutionGate.authorize_implementation(issue, intake_case.project_id)
    assert Repo.get!(IntakeCase, intake_case.id).repair_approved_at == nil
    refute_receive :implementation_refresh_requested
  end

  test "acknowledgement is idempotent and invalid action arguments are rejected" do
    {_project, _rule, _connection, intake_case} = case_fixture!()

    assert {:error, :stale_version} = Actions.acknowledge(intake_case.id, intake_case.lock_version + 1)
    assert {:ok, acknowledged} = Actions.acknowledge(intake_case.id, intake_case.lock_version)
    assert {:ok, duplicate} = Actions.acknowledge(acknowledged.id, acknowledged.lock_version)

    assert duplicate.acknowledged_at == acknowledged.acknowledged_at
    assert duplicate.lock_version == acknowledged.lock_version

    assert Repo.aggregate(
             from(event in IntakeEvent,
               where: event.case_id == ^intake_case.id and event.type == "case_acknowledged"
             ),
             :count
           ) == 1

    assert {:error, :invalid_action} = Actions.acknowledge(nil, 1)
    assert {:error, :invalid_action} = Actions.acknowledge(intake_case.id, 1, :invalid_options)
    assert {:error, :invalid_action} = Actions.approve_repair(intake_case.id, 0, 1, true)
    assert {:error, :invalid_action} = Actions.reanalyze(intake_case.id, 1, :not_confirmed)
  end

  test "valid actions for a missing case return not found" do
    case_id = Ecto.UUID.generate()

    assert {:error, :not_found} = Actions.acknowledge(case_id, 1)
    assert {:error, :not_found} = Actions.approve_repair(case_id, 1, 1, true)

    assert {:error, :not_found} =
             Actions.reanalyze(case_id, 1, true, analysis_profile: %{model: "synthetic-analysis-model", effort: "medium"})
  end

  test "approve requires a ready analysis, a published comment, confirmed Linear, and current versions" do
    {_project, _rule, _connection, not_ready} = case_fixture!(analysis_status: "failed", analysis_result_status: "failed")
    {_project, _rule, _connection, unpublished} = case_fixture!(published?: false)
    {_project, _rule, _connection, unconfirmed} = case_fixture!(linear_confirmed?: false)
    {_project, _rule, _connection, current} = case_fixture!()

    assert {:error, :analysis_not_ready} =
             Actions.approve_repair(not_ready.id, not_ready.lock_version, 1, true)

    {_project, _rule, _connection, incomplete_analysis} =
      case_fixture!(analysis_status: "ready", analysis_result_status: "failed")

    assert {:error, :analysis_not_ready} =
             Actions.approve_repair(incomplete_analysis.id, incomplete_analysis.lock_version, 1, true)

    assert {:error, :analysis_not_published} =
             Actions.approve_repair(unpublished.id, unpublished.lock_version, 1, true)

    assert {:error, :linear_not_confirmed} =
             Actions.approve_repair(unconfirmed.id, unconfirmed.lock_version, 1, true)

    assert {:error, :stale_version} =
             Actions.approve_repair(current.id, current.lock_version + 1, 1, true)

    assert {:error, :stale_version} =
             Actions.approve_repair(current.id, current.lock_version, 2, true)

    assert {:error, :confirmation_required} =
             Actions.approve_repair(current.id, current.lock_version, 1, false)
  end

  test "approval is idempotent for one analysis version and refresh runs after commit" do
    {_project, _rule, _connection, intake_case} = case_fixture!()
    parent = self()
    issue = managed_issue(intake_case)

    assert {:error, :analysis_only} = ExecutionGate.authorize_implementation(issue, intake_case.project_id)

    refresh_fun = fn ->
      refute Repo.in_transaction?()
      persisted = Repo.get!(IntakeCase, intake_case.id)
      assert persisted.repair_approved_version == 1
      send(parent, :implementation_refresh_requested)
    end

    assert {:ok, approved} =
             Actions.approve_repair(intake_case.id, intake_case.lock_version, 1, true,
               clock: &now/0,
               refresh_fun: refresh_fun
             )

    assert approved.repair_approved_version == 1
    assert :ok = ExecutionGate.authorize_implementation(issue, intake_case.project_id)
    assert_receive :implementation_refresh_requested

    assert {:ok, duplicate} =
             Actions.approve_repair(intake_case.id, intake_case.lock_version, 1, true, refresh_fun: fn -> send(parent, :duplicate_refresh_requested) end)

    assert duplicate.repair_approved_at == approved.repair_approved_at
    assert duplicate.lock_version == approved.lock_version
    assert Repo.aggregate(from(event in IntakeEvent, where: event.case_id == ^intake_case.id and event.type == "repair_approved"), :count) == 1
    refute_receive :duplicate_refresh_requested
  end

  test "approval remains committed and warns when the orchestrator is unavailable" do
    {_project, _rule, _connection, intake_case} = case_fixture!()

    log =
      capture_log(fn ->
        assert {:ok, approved} =
                 Actions.approve_repair(intake_case.id, intake_case.lock_version, 1, true, refresh_fun: fn -> :unavailable end)

        assert approved.repair_approved_version == 1
        assert Repo.get!(IntakeCase, intake_case.id).repair_approved_version == 1
      end)

    assert log =~ "case_id=#{intake_case.id}"
    assert log =~ "reason=:orchestrator_unavailable"
  end

  test "approval remains committed and warns without logging refresh error details" do
    {_project, _rule, _connection, intake_case} = case_fixture!()
    refresh_error = %{message: "synthetic provider secret"}
    refresh_calls = make_ref()

    log =
      capture_log(fn ->
        assert {:ok, approved} =
                 Actions.approve_repair(intake_case.id, intake_case.lock_version, 1, true,
                   refresh_fun: fn ->
                     Process.put(refresh_calls, Process.get(refresh_calls, 0) + 1)
                     {:error, refresh_error}
                   end
                 )

        assert approved.repair_approved_version == 1
        assert Repo.get!(IntakeCase, intake_case.id).repair_approved_version == 1
      end)

    assert log =~ "case_id=#{intake_case.id}"
    assert log =~ "reason=:refresh_error"
    refute log =~ "synthetic provider secret"
    assert Process.get(refresh_calls) == 1
    assert Repo.aggregate(from(event in IntakeEvent, where: event.case_id == ^intake_case.id and event.type == "repair_approved"), :count) == 1
  end

  test "approval remains committed when refresh raises or throws" do
    failures = [
      {fn -> raise "synthetic provider secret" end, "reason=RuntimeError"},
      {fn -> throw("synthetic provider secret") end, "reason=:refresh_failed"}
    ]

    for {refresh_fun, expected_reason} <- failures do
      {_project, _rule, _connection, intake_case} = case_fixture!()

      log =
        capture_log(fn ->
          assert {:ok, approved} =
                   Actions.approve_repair(intake_case.id, intake_case.lock_version, 1, true, refresh_fun: refresh_fun)

          assert approved.repair_approved_version == 1
          assert Repo.get!(IntakeCase, intake_case.id).repair_approved_version == 1
        end)

      assert log =~ "case_id=#{intake_case.id}"
      assert log =~ expected_reason
      refute log =~ "synthetic provider secret"
    end
  end

  test "reanalyze creates a queued version, clears acknowledgement, and refuses approved cases" do
    {_project, _rule, _connection, intake_case} = case_fixture!(acknowledged?: true)
    parent = self()

    assert {:error, :analysis_profile_unavailable} =
             Actions.reanalyze(intake_case.id, intake_case.lock_version, true)

    assert {:ok, reanalyzed} =
             Actions.reanalyze(intake_case.id, intake_case.lock_version, true,
               analysis_profile: %{model: "synthetic-analysis-model", effort: "medium"},
               clock: &now/0,
               refresh_fun: fn -> send(parent, :implementation_refresh_requested) end
             )

    assert reanalyzed.analysis_version == 2
    assert reanalyzed.analysis_status == "queued"
    assert is_nil(reanalyzed.acknowledged_at)
    assert reanalyzed.lock_version == intake_case.lock_version + 1
    assert Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 1).status == "succeeded"
    reanalysis = Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 2)
    assert reanalysis.status == "queued"
    assert reanalysis.input_snapshot["analysis_version"] == 2

    delivery = Repo.get_by!(IntegrationDelivery, dedupe_key: "case:#{intake_case.id}:analysis:2")
    assert delivery.operation == "analysis"
    assert delivery.status == "pending"
    assert delivery.payload["version"] == 2
    assert Repo.exists?(from(event in IntakeEvent, where: event.case_id == ^intake_case.id and event.type == "analysis_reanalyze_requested" and event.actor == "operator"))
    refute_receive :implementation_refresh_requested

    {_project, _rule, _connection, approved} = case_fixture!(approved?: true)

    assert {:error, :repair_already_approved} =
             Actions.reanalyze(approved.id, approved.lock_version, true, analysis_profile: %{model: "synthetic-analysis-model", effort: "medium"})
  end

  test "reanalyze rejects malformed profiles without changing the current case" do
    {_project, _rule, _connection, intake_case} = case_fixture!(acknowledged?: true)

    assert {:error, :analysis_profile_unavailable} =
             Actions.reanalyze(intake_case.id, intake_case.lock_version, true, analysis_profile: %{model: " ", effort: "medium"})

    assert {:error, :analysis_profile_unavailable} =
             Actions.reanalyze(intake_case.id, intake_case.lock_version, true, analysis_profile: :invalid)

    persisted = Repo.get!(IntakeCase, intake_case.id)
    assert persisted.analysis_version == intake_case.analysis_version
    assert persisted.lock_version == intake_case.lock_version
    assert persisted.acknowledged_at == intake_case.acknowledged_at
    refute Repo.get_by(IntakeAnalysis, case_id: intake_case.id, version: 2)
  end

  test "reanalyze rolls back the case update when a version insert conflicts in PostgreSQL" do
    {_project, _rule, _connection, intake_case} = case_fixture!(acknowledged?: true)

    %IntakeAnalysis{}
    |> IntakeAnalysis.changeset(%{
      case_id: intake_case.id,
      version: 2,
      status: "queued",
      input_snapshot: %{"analysis_version" => 2},
      model: "synthetic-analysis-model",
      effort: "medium"
    })
    |> Repo.insert!()

    assert {:error, :action_unavailable} =
             Actions.reanalyze(intake_case.id, intake_case.lock_version, true, analysis_profile: %{model: "synthetic-analysis-model", effort: "medium"})

    persisted = Repo.get!(IntakeCase, intake_case.id)
    assert persisted.analysis_version == 1
    assert persisted.lock_version == intake_case.lock_version
    assert persisted.acknowledged_at == intake_case.acknowledged_at

    refute Repo.exists?(
             from(event in IntakeEvent,
               where: event.case_id == ^intake_case.id and event.type == "analysis_reanalyze_requested"
             )
           )

    refute Repo.exists?(
             from(delivery in IntegrationDelivery,
               where: delivery.case_id == ^intake_case.id and delivery.operation == "analysis"
             )
           )
  end

  test "approve and reanalyze race on independent PostgreSQL connections with one durable winner" do
    case_attrs =
      Sandbox.unboxed_run(Repo, fn ->
        {_project, _rule, _connection, intake_case} = case_fixture!()
        {intake_case.id, intake_case.lock_version, intake_case.project_id, intake_case.linear_issue_id}
      end)

    {case_id, lock_version, _project_id, _linear_issue_id} = case_attrs
    schedule_committed_fixture_cleanup(case_id)
    parent = self()
    approval_refresh = fn -> send(parent, :implementation_refresh_requested) end

    operations = [
      {:approve,
       fn ->
         Actions.approve_repair(
           case_id,
           lock_version,
           1,
           true,
           refresh_fun: approval_refresh
         )
       end},
      {:reanalyze,
       fn ->
         Actions.reanalyze(case_id, lock_version, true, analysis_profile: %{model: "synthetic-analysis-model", effort: "medium"})
       end}
    ]

    tasks =
      Enum.map(operations, fn {name, operation} ->
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo)

          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:postgres_action_ready, name, self(), backend_pid})

            receive do
              :run_action -> operation.()
            after
              5_000 -> flunk("timed out waiting to run PostgreSQL action")
            end
          end)
        end)
      end)

    workers =
      for _ <- operations do
        receive do
          {:postgres_action_ready, name, worker, backend_pid} -> {name, worker, backend_pid}
        after
          5_000 -> flunk("timed out waiting for PostgreSQL action workers")
        end
      end

    assert workers |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> length() == 2
    Enum.each(workers, fn {_name, worker, _backend_pid} -> send(worker, :run_action) end)
    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert Enum.count(results, &match?({:ok, %IntakeCase{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, reason} when reason in [:stale_version, :repair_already_approved], &1)) == 1

    :ok = Sandbox.checkout(Repo)
    persisted = Repo.get!(IntakeCase, case_id)

    assert (persisted.analysis_version == 2 and is_nil(persisted.repair_approved_at)) or
             (persisted.analysis_version == 1 and persisted.repair_approved_version == 1)
  end

  defp case_fixture!(opts \\ []) do
    project =
      %Project{}
      |> Project.changeset(%{
        slug: "intake-actions-#{System.unique_integer([:positive])}",
        linear_project_slug: "intake-actions",
        linear_team_key: "OPS",
        forge_owner: "example",
        forge_repo: "synthetic",
        forge_base_branch: "main",
        config_version: 1,
        config: %{}
      })
      |> Repo.insert!()

    connection =
      %IntegrationConnection{}
      |> IntegrationConnection.changeset(%{
        kind: "jira_cloud",
        name: "Intake actions Jira",
        settings: %{site_url: "https://actions-#{System.unique_integer([:positive])}.atlassian.net"},
        enabled: true
      })
      |> Repo.insert!()

    rule =
      %AutomationRule{}
      |> AutomationRule.changeset(%{
        project_id: project.id,
        jira_connection_id: connection.id,
        name: "Intake actions rule",
        source_type: "board",
        source_id: "42",
        priority_ids: ["1"],
        interval_seconds: 300,
        initial_policy: "new_matches_only",
        linear_team_id: "synthetic-team",
        linear_project_id: "synthetic-project",
        linear_todo_state_id: "synthetic-todo",
        linear_hold_label_id: "synthetic-hold"
      })
      |> Repo.insert!()

    timestamp = now()
    approved? = Keyword.get(opts, :approved?, false)
    analysis_version = Keyword.get(opts, :analysis_version, 1)

    intake_case =
      %IntakeCase{}
      |> IntakeCase.changeset(%{
        project_id: project.id,
        rule_id: rule.id,
        jira_connection_id: connection.id,
        jira_issue_id: "issue-#{System.unique_integer([:positive])}",
        jira_key: "OPS-#{System.unique_integer([:positive])}",
        jira_url: "https://example.atlassian.net/browse/OPS-1",
        title: "Synthetic intake case",
        description_text: "Synthetic description",
        priority_id: "1",
        priority_name: "Highest",
        jira_updated_at: timestamp,
        detected_at: timestamp,
        rule_snapshot: %{name: rule.name},
        linear_issue_id: Ecto.UUID.generate(),
        linear_identifier: "OPS-1",
        linear_url: "https://linear.example/issue/OPS-1",
        linear_state_name: "Todo",
        linear_confirmed_at: if(Keyword.get(opts, :linear_confirmed?, true), do: timestamp),
        analysis_version: analysis_version,
        analysis_status: Keyword.get(opts, :analysis_status, "ready"),
        acknowledged_at: if(Keyword.get(opts, :acknowledged?, false), do: timestamp),
        repair_approved_at: if(approved?, do: timestamp),
        repair_approved_version: if(approved?, do: analysis_version),
        lock_version: 1
      })
      |> Repo.insert!()

    analysis_status = Keyword.get(opts, :analysis_result_status, "succeeded")

    %IntakeAnalysis{}
    |> IntakeAnalysis.changeset(%{
      case_id: intake_case.id,
      version: analysis_version,
      status: analysis_status,
      input_snapshot: %{
        "case_ref" => "jira_#{intake_case.id}",
        "jira_key" => intake_case.jira_key,
        "analysis_version" => analysis_version
      },
      result: %{"summary" => "Synthetic result", "needs_input" => false},
      model: "synthetic-analysis-model",
      effort: "medium",
      completed_at: timestamp
    })
    |> Repo.insert!()

    if Keyword.get(opts, :published?, true) do
      %IntegrationDelivery{}
      |> IntegrationDelivery.changeset(%{
        case_id: intake_case.id,
        connection_id: connection.id,
        operation: "jira_comment",
        dedupe_key: "case:#{intake_case.id}:jira-comment:#{analysis_version}",
        payload: %{"version" => analysis_version},
        status: "succeeded",
        attempts: 1,
        next_attempt_at: timestamp,
        provider_id: "synthetic-comment-#{Ecto.UUID.generate()}",
        sent_at: timestamp
      })
      |> Repo.insert!()
    end

    {project, rule, connection, intake_case}
  end

  defp managed_issue(intake_case) do
    %Issue{
      id: intake_case.linear_issue_id,
      identifier: intake_case.linear_identifier,
      title: intake_case.title,
      description: "Harmony case: #{intake_case.id}",
      state: "Todo",
      labels: ["harmony:analysis-only"]
    }
  end

  defp schedule_committed_fixture_cleanup(case_id) do
    config = database_opts()

    on_exit(fn ->
      with_connection(config, fn database ->
        %{rows: [[rule_id, connection_id, project_id]]} =
          Postgrex.query!(
            database,
            "SELECT rule_id, jira_connection_id, project_id FROM intake_cases WHERE id = $1",
            [uuid_binary(case_id)]
          )

        Postgrex.query!(database, "DELETE FROM intake_events WHERE case_id = $1", [uuid_binary(case_id)])
        Postgrex.query!(database, "DELETE FROM integration_deliveries WHERE case_id = $1", [uuid_binary(case_id)])
        Postgrex.query!(database, "DELETE FROM intake_analyses WHERE case_id = $1", [uuid_binary(case_id)])
        Postgrex.query!(database, "DELETE FROM intake_cases WHERE id = $1", [uuid_binary(case_id)])
        Postgrex.query!(database, "DELETE FROM automation_rules WHERE id = $1", [rule_id])
        Postgrex.query!(database, "DELETE FROM integration_connections WHERE id = $1", [connection_id])
        Postgrex.query!(database, "DELETE FROM projects WHERE id = $1", [project_id])
      end)
    end)
  end

  defp with_connection(config, fun) do
    {:ok, connection} = Postgrex.start_link(config)

    try do
      fun.(connection)
    after
      GenServer.stop(connection)
    end
  end

  defp database_opts do
    Repo.config()
    |> Keyword.take([:hostname, :port, :username, :password, :database])
  end

  defp uuid_binary(uuid), do: Ecto.UUID.dump!(uuid)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
