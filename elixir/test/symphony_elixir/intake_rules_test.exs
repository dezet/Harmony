defmodule SymphonyElixir.IntakeRulesTest do
  use SymphonyElixir.TestSupport

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake
  alias SymphonyElixir.Intake.Rules
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{AutomationRule, IntakeCase, IntegrationConnection, Project}

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "interval boundaries, priority IDs and recipients are validated" do
    attrs = rule_attrs()

    assert {:error, changeset} = Rules.create(%{attrs | interval_seconds: 59})
    assert Keyword.has_key?(changeset.errors, :interval_seconds)

    assert {:error, changeset} = Rules.create(%{attrs | interval_seconds: 86_401})
    assert Keyword.has_key?(changeset.errors, :interval_seconds)

    assert {:error, changeset} = Rules.create(%{attrs | priority_ids: []})
    assert Keyword.has_key?(changeset.errors, :priority_ids)

    assert {:error, changeset} = Rules.create(%{attrs | priority_ids: ["", " "]})
    assert Keyword.has_key?(changeset.errors, :priority_ids)

    email = connection!("smtp", %{host: "smtp.example.test"})

    assert {:error, changeset} =
             Rules.create(Map.merge(attrs, %{email_connection_id: email.id, email_recipients: []}))

    assert Keyword.has_key?(changeset.errors, :email_recipients)
  end

  test "a rule requires connections with the matching provider kind" do
    jira = connection!("jira_cloud", %{site_url: "https://other-jira.example.test"})
    attrs = Map.merge(rule_attrs(), %{jira_connection_id: jira.id, email_connection_id: jira.id, email_recipients: ["ops@example.test"]})

    assert {:error, changeset} = Rules.create(attrs)
    assert Keyword.has_key?(changeset.errors, :email_connection_id)
  end

  test "snapshot contains the target and recipients and PATCH increments its version" do
    email = connection!("smtp", %{host: "smtp.example.test"})
    sms = connection!("smsapi", %{sender: "Harmony"})

    attrs =
      rule_attrs()
      |> Map.merge(%{
        email_connection_id: email.id,
        email_recipients: ["ops@example.test"],
        sms_connection_id: sms.id,
        sms_recipients: ["+48123123123"]
      })

    assert {:ok, rule} = Rules.create(Map.put(attrs, :enabled, true))
    refute rule.enabled
    assert rule.activation_status == "idle"
    assert rule.config_version == 1

    snapshot = Rules.snapshot(rule)
    assert snapshot.project_id == rule.project_id
    assert snapshot.project_name =~ "intake-rules-"
    assert snapshot.jira_connection_id == rule.jira_connection_id
    assert snapshot.jira_connection_name =~ "jira_cloud-"
    assert snapshot.source_type == "board"
    assert snapshot.source_id == "42"
    assert snapshot.priority_ids == ["1"]
    assert snapshot.linear_team_id == "team-id"
    assert snapshot.linear_project_id == "project-id"
    assert snapshot.linear_todo_state_id == "todo-id"
    assert snapshot.linear_hold_label_id == "hold-id"
    assert snapshot.email_recipients == ["ops@example.test"]
    assert snapshot.sms_recipients == ["+48123123123"]
    assert snapshot.config_version == 1
    assert is_binary(snapshot.qualified_at)

    assert {:ok, patched} = Rules.patch(rule, %{name: "Renamed"})
    assert patched.name == "Renamed"
    assert patched.config_version == 2
  end

  test "changing source disables an active rule and target fields stay immutable" do
    assert {:ok, rule} = Rules.create(rule_attrs())
    assert {:ok, active} = Rules.activate(rule)
    assert active.enabled
    assert active.activated_at

    assert {:error, :immutable_after_activation} =
             Rules.patch(active, %{linear_project_id: "other-project"})

    assert {:ok, disabled} = Rules.patch(active, %{source_id: "99"})
    refute disabled.enabled
    assert disabled.activation_status == "idle"
    assert disabled.config_version == active.config_version + 1
  end

  test "only one active rule may claim a source" do
    attrs = rule_attrs()
    assert {:ok, first} = Rules.create(attrs)
    assert {:ok, second} = Rules.create(%{attrs | name: "Second"})
    assert {:ok, _active} = Rules.activate(first)

    assert {:error, :source_conflict} = Rules.activate(second)
    second = Repo.get!(AutomationRule, second.id)
    refute second.enabled
  end

  test "disabling a rule keeps cases and their protection intact" do
    assert {:ok, rule} = Rules.create(rule_attrs())
    assert {:ok, active} = Rules.activate(rule)

    intake_case =
      %IntakeCase{}
      |> IntakeCase.changeset(%{
        project_id: active.project_id,
        rule_id: active.id,
        jira_connection_id: active.jira_connection_id,
        jira_issue_id: "10001",
        jira_key: "OPS-1",
        jira_url: "https://jira.example.test/browse/OPS-1",
        title: "Case",
        description_text: "Description",
        priority_id: "1",
        priority_name: "P1",
        jira_updated_at: now(),
        detected_at: now(),
        rule_snapshot: Intake.snapshot_case_attrs(%{}, active).rule_snapshot,
        linear_issue_id: Ecto.UUID.generate(),
        analysis_version: 1,
        analysis_status: "queued",
        lock_version: 1
      })
      |> Repo.insert!()

    assert {:ok, disabled} = Rules.disable(active)
    refute disabled.enabled
    stored_case = Repo.get!(IntakeCase, intake_case.id)
    assert stored_case.linear_issue_id == intake_case.linear_issue_id
    assert stored_case.rule_id == active.id
    assert stored_case.rule_snapshot["linear_hold_label_id"] == "hold-id"
  end

  defp rule_attrs do
    project = project!()
    jira = connection!("jira_cloud", %{site_url: "https://jira.example.test"})

    %{
      project_id: project.id,
      jira_connection_id: jira.id,
      name: "Rule",
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
      sms_recipients: [],
      enabled: false,
      config_version: 1,
      activation_status: "idle",
      lock_version: 1
    }
  end

  defp project! do
    %Project{}
    |> Project.changeset(%{
      slug: "intake-rules-#{System.unique_integer([:positive])}",
      forge_owner: "example",
      forge_repo: "harmony",
      forge_base_branch: "main",
      config: %{},
      config_version: 1,
      ui_color: "purple"
    })
    |> Repo.insert!()
  end

  defp connection!(kind, settings) do
    %IntegrationConnection{}
    |> IntegrationConnection.changeset(%{
      kind: kind,
      name: "#{kind}-#{System.unique_integer([:positive])}",
      settings: settings,
      secret: "secret"
    })
    |> Repo.insert!()
  end

  defp now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end
end
