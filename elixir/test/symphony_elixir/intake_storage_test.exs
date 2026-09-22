defmodule SymphonyElixir.IntakeStorageTest do
  use SymphonyElixir.TestSupport

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.AutomationRule
  alias SymphonyElixir.Storage.AutomationScan
  alias SymphonyElixir.Storage.IntakeAnalysis
  alias SymphonyElixir.Storage.IntakeCase
  alias SymphonyElixir.Storage.IntakeEvent
  alias SymphonyElixir.Storage.IntegrationConnection
  alias SymphonyElixir.Storage.IntegrationDelivery
  alias SymphonyElixir.Storage.JiraObservation
  alias SymphonyElixir.Storage.Project
  alias SymphonyElixir.Storage.WorkRun

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "database uniqueness rejects duplicate cases, Linear UUIDs, analysis versions, and delivery keys" do
    project = project!()
    connection = connection!()
    rule = rule!(project, connection)
    first_case = intake_case!(project, rule, connection)

    assert {:error, duplicate_case} =
             IntakeCase.changeset(
               %IntakeCase{},
               case_attrs(project, rule, connection, jira_issue_id: "same-issue", jira_key: "OPS-2")
             )
             |> Repo.insert()

    assert has_constraint_error?(duplicate_case, :jira_issue_id)

    other_connection = connection!()
    other_rule = rule!(project, other_connection, source_id: "43")

    assert {:error, duplicate_linear} =
             IntakeCase.changeset(
               %IntakeCase{},
               case_attrs(project, other_rule, other_connection,
                 jira_issue_id: "different-issue",
                 jira_key: "OPS-3",
                 linear_issue_id: first_case.linear_issue_id
               )
             )
             |> Repo.insert()

    assert has_constraint_error?(duplicate_linear, :linear_issue_id)

    analysis_attrs = %{
      case_id: first_case.id,
      version: 1,
      status: "queued",
      input_snapshot: %{source: "jira:OPS-1"},
      model: "analysis-model",
      effort: "medium"
    }

    assert {:ok, _analysis} = IntakeAnalysis.changeset(%IntakeAnalysis{}, analysis_attrs) |> Repo.insert()

    assert {:error, duplicate_analysis} =
             IntakeAnalysis.changeset(%IntakeAnalysis{}, analysis_attrs) |> Repo.insert()

    assert has_constraint_error?(duplicate_analysis, :version)

    delivery_attrs = %{
      operation: "email",
      dedupe_key: "case:#{first_case.id}:email:recipient:v1",
      payload: %{case_id: first_case.id},
      status: "pending",
      attempts: 0,
      next_attempt_at: now()
    }

    assert {:ok, _delivery} =
             IntegrationDelivery.changeset(%IntegrationDelivery{}, delivery_attrs) |> Repo.insert()

    assert {:error, duplicate_delivery} =
             IntegrationDelivery.changeset(%IntegrationDelivery{}, delivery_attrs) |> Repo.insert()

    assert has_constraint_error?(duplicate_delivery, :dedupe_key)
  end

  test "integration secrets round-trip through Cloak and are encrypted in PostgreSQL" do
    connection = connection!(secret: "jira-token-for-storage")

    assert connection.secret == "jira-token-for-storage"

    %{rows: [[raw_secret]]} =
      Repo.query!("SELECT secret FROM integration_connections WHERE id = $1", [uuid_binary(connection.id)])

    assert is_binary(raw_secret)
    refute raw_secret == "jira-token-for-storage"
    refute raw_secret =~ "jira-token-for-storage"

    loaded = Repo.get!(IntegrationConnection, connection.id)
    assert loaded.secret == "jira-token-for-storage"
  end

  test "all intake records persist with their foreign keys and domain defaults" do
    project = project!()
    connection = connection!()
    rule = rule!(project, connection)
    scan_time = now()

    observation =
      JiraObservation.changeset(%JiraObservation{}, %{
        jira_connection_id: connection.id,
        rule_id: rule.id,
        jira_issue_id: "10001",
        first_seen_at: scan_time,
        last_seen_at: scan_time,
        baseline_excluded: true
      })
      |> Repo.insert!()

    scan =
      AutomationScan.changeset(%AutomationScan{}, %{
        rule_id: rule.id,
        rule_config_version: 1,
        mode: "baseline",
        status: "succeeded",
        generation: Ecto.UUID.generate(),
        match_count: 1,
        accepted_count: 0
      })
      |> Repo.insert!()

    intake_case = intake_case!(project, rule, connection)

    analysis =
      IntakeAnalysis.changeset(%IntakeAnalysis{}, %{
        case_id: intake_case.id,
        version: 1,
        status: "needs_input",
        input_snapshot: %{jira_key: intake_case.jira_key},
        result: %{needs_input: true},
        model: "analysis-model",
        effort: "medium"
      })
      |> Repo.insert!()

    delivery =
      IntegrationDelivery.changeset(%IntegrationDelivery{}, %{
        case_id: intake_case.id,
        connection_id: connection.id,
        operation: "jira_comment",
        dedupe_key: "case:#{intake_case.id}:jira-comment:1",
        payload: %{version: 1},
        next_attempt_at: scan_time
      })
      |> Repo.insert!()

    event =
      IntakeEvent.changeset(%IntakeEvent{}, %{
        case_id: intake_case.id,
        rule_id: rule.id,
        type: "detected",
        payload: %{jira_issue_id: intake_case.jira_issue_id},
        actor: "system",
        occurred_at: scan_time
      })
      |> Repo.insert!()

    assert observation.rule_id == rule.id
    assert observation.baseline_excluded
    assert scan.status == "succeeded"
    assert analysis.status == "needs_input"
    assert delivery.status == "pending"
    assert event.actor == "system"
    assert Repo.get!(IntakeEvent, event.id).case_id == intake_case.id
  end

  test "two concurrent PostgreSQL inserts for one Jira issue leave one case" do
    ids = %{project: Ecto.UUID.generate(), connection: Ecto.UUID.generate(), rule: Ecto.UUID.generate()}
    issue_id = "concurrent-#{System.unique_integer([:positive])}"
    parent = self()

    with_connection(fn database ->
      insert_raw_fixture!(database, ids)

      on_exit(fn ->
        with_connection(fn cleanup -> cleanup_raw_fixture!(cleanup, ids) end)
      end)

      tasks =
        for index <- 1..2 do
          Task.async(fn ->
            {:ok, connection} = Postgrex.start_link(database_opts())
            send(parent, {:postgres_ready, self(), connection})

            receive do
              :insert ->
                result =
                  try do
                    Postgrex.query!(connection, raw_case_insert_sql(), [
                      uuid_binary(Ecto.UUID.generate()),
                      uuid_binary(ids.project),
                      uuid_binary(ids.rule),
                      uuid_binary(ids.connection),
                      issue_id,
                      "OPS-#{index}",
                      uuid_binary(Ecto.UUID.generate())
                    ])

                    :ok
                  rescue
                    error in Postgrex.Error -> {:error, error.postgres.code}
                  end

                GenServer.stop(connection)
                result
            end
          end)
        end

      workers =
        for _ <- 1..2 do
          receive do
            {:postgres_ready, worker, connection} -> {worker, connection}
          after
            5_000 -> flunk("timed out waiting for PostgreSQL workers")
          end
        end

      Enum.each(workers, fn {worker, _connection} -> send(worker, :insert) end)
      results = Enum.map(tasks, &Task.await(&1, 10_000))

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &match?({:error, :unique_violation}, &1)) == 1

      %{rows: [[count]]} =
        Postgrex.query!(database, "SELECT count(*) FROM intake_cases WHERE rule_id = $1 AND jira_issue_id = $2", [
          uuid_binary(ids.rule),
          issue_id
        ])

      assert count == 1
    end)
  end

  test "project presentation migration preserves existing project state and work runs" do
    project =
      project!(
        config: %{workflow: "legacy", setting: true},
        ui_color: "purple"
      )

    {:ok, project} =
      SymphonyElixir.Storage.update_project_secrets(project, %{"tracker_secret" => "linear-token"})

    work_run =
      WorkRun.changeset(%WorkRun{}, %{
        project_id: project.id,
        type: "legacy",
        status: "queued",
        payload: %{title: "Existing work"}
      })
      |> Repo.insert!()

    stored_project = Repo.get!(Project, project.id)
    stored_run = Repo.get!(WorkRun, work_run.id)

    assert stored_project.ui_color == "purple"
    assert stored_project.config == %{"workflow" => "legacy", "setting" => true}
    assert stored_project.tracker_secret == "linear-token"
    assert stored_run.payload == %{"title" => "Existing work"}
    assert stored_run.project_id == stored_project.id
  end

  defp project!(attrs \\ []) do
    defaults = %{
      slug: "intake-storage-#{System.unique_integer([:positive])}",
      forge_owner: "example",
      forge_repo: "harmony",
      forge_base_branch: "main",
      config: %{},
      config_version: 1,
      ui_color: "purple"
    }

    %Project{}
    |> Project.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp connection!(attrs \\ []) do
    defaults = %{
      kind: "jira_cloud",
      name: "Jira #{System.unique_integer([:positive])}",
      settings: %{site_url: "https://example-#{System.unique_integer([:positive])}.atlassian.net"},
      secret: "jira-token"
    }

    %IntegrationConnection{}
    |> IntegrationConnection.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp rule!(project, connection, attrs \\ []) do
    defaults = %{
      project_id: project.id,
      jira_connection_id: connection.id,
      name: "Rule #{System.unique_integer([:positive])}",
      source_type: "board",
      source_id: "42",
      priority_ids: ["1"],
      interval_seconds: 300,
      initial_policy: "new_matches_only",
      linear_team_id: "11111111-1111-4111-8111-111111111111",
      linear_project_id: "22222222-2222-4222-8222-222222222222",
      linear_todo_state_id: "33333333-3333-4333-8333-333333333333",
      linear_hold_label_id: "44444444-4444-4444-8444-444444444444",
      email_recipients: [],
      sms_recipients: [],
      enabled: false,
      config_version: 1,
      activation_status: "idle",
      lock_version: 1
    }

    %AutomationRule{}
    |> AutomationRule.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp intake_case!(project, rule, connection, attrs \\ []) do
    %IntakeCase{}
    |> IntakeCase.changeset(case_attrs(project, rule, connection, attrs))
    |> Repo.insert!()
  end

  defp case_attrs(project, rule, connection, attrs) do
    timestamp = now()

    defaults = %{
      project_id: project.id,
      rule_id: rule.id,
      jira_connection_id: connection.id,
      jira_issue_id: "same-issue",
      jira_key: "OPS-1",
      jira_url: "https://example.atlassian.net/browse/OPS-1",
      title: "An intake case",
      description_text: "Description",
      priority_id: "1",
      priority_name: "Highest",
      jira_updated_at: timestamp,
      detected_at: timestamp,
      rule_snapshot: %{name: rule.name},
      linear_issue_id: Ecto.UUID.generate(),
      analysis_version: 1,
      analysis_status: "queued",
      lock_version: 1
    }

    Map.merge(defaults, Map.new(attrs))
  end

  defp has_constraint_error?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn {error_field, {_message, metadata}} ->
      error_field == field and metadata[:constraint] == :unique
    end)
  end

  defp has_constraint_error?(_, _field), do: false

  defp now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end

  defp uuid_binary(uuid), do: Ecto.UUID.dump!(uuid)

  defp database_opts do
    Repo.config()
    |> Keyword.take([:hostname, :port, :username, :password, :database])
  end

  defp with_connection(fun) do
    {:ok, connection} = Postgrex.start_link(database_opts())

    try do
      fun.(connection)
    after
      GenServer.stop(connection)
    end
  end

  defp insert_raw_fixture!(database, %{project: project_id, connection: connection_id, rule: rule_id}) do
    Postgrex.query!(database, "INSERT INTO projects (id, slug, inserted_at, updated_at) VALUES ($1, $2, now(), now())", [
      uuid_binary(project_id),
      "concurrency-#{project_id}"
    ])

    Postgrex.query!(
      database,
      "INSERT INTO integration_connections (id, kind, name, settings, secret, inserted_at, updated_at) VALUES ($1, 'jira_cloud', $2, '{\"site_url\":\"https://concurrency.atlassian.net\"}', NULL, now(), now())",
      [uuid_binary(connection_id), "Concurrency connection"]
    )

    Postgrex.query!(
      database,
      "INSERT INTO automation_rules (id, project_id, jira_connection_id, name, source_type, source_id, priority_ids, linear_team_id, linear_project_id, linear_todo_state_id, linear_hold_label_id, inserted_at, updated_at) VALUES ($1, $2, $3, 'Concurrency rule', 'board', '42', ARRAY['1']::text[], 'team', 'project', 'todo', 'hold', now(), now())",
      [uuid_binary(rule_id), uuid_binary(project_id), uuid_binary(connection_id)]
    )
  end

  defp cleanup_raw_fixture!(database, %{project: project_id, connection: connection_id, rule: rule_id}) do
    Postgrex.query!(database, "DELETE FROM intake_cases WHERE rule_id = $1", [uuid_binary(rule_id)])
    Postgrex.query!(database, "DELETE FROM automation_rules WHERE id = $1", [uuid_binary(rule_id)])
    Postgrex.query!(database, "DELETE FROM integration_connections WHERE id = $1", [uuid_binary(connection_id)])
    Postgrex.query!(database, "DELETE FROM projects WHERE id = $1", [uuid_binary(project_id)])
  end

  defp raw_case_insert_sql do
    """
    INSERT INTO intake_cases (
      id, project_id, rule_id, jira_connection_id, jira_issue_id, jira_key, jira_url,
      title, description_text, priority_id, priority_name, jira_updated_at, detected_at,
      rule_snapshot, linear_issue_id, analysis_version, analysis_status, lock_version,
      inserted_at, updated_at
    ) VALUES ($1, $2, $3, $4, $5, $6, 'https://concurrency.atlassian.net/browse/OPS-1',
      'Concurrent case', 'Description', '1', 'Highest', now(), now(), '{}'::jsonb, $7, 1, 'queued', 1, now(), now())
    """
  end
end
