defmodule SymphonyElixir.IntakeRulesTest do
  use SymphonyElixir.TestSupport

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake
  alias SymphonyElixir.Intake.Connections
  alias SymphonyElixir.Intake.Rules
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{AutomationRule, IntakeCase, IntegrationConnection, Project}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), intake_effects_enabled: true)
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

  test "string-key rule input ignores unknown fields and normalizes recipients" do
    email = connection!("smtp", %{host: "smtp.example.test"})
    sms = connection!("smsapi", %{sender: "Harmony"})

    attrs =
      rule_attrs()
      |> Map.merge(%{
        source_id: " 42 ",
        email_connection_id: email.id,
        email_recipients: [" Ops@EXAMPLE.TEST ", "Ops@example.test"],
        sms_connection_id: sms.id,
        sms_recipients: [" +48123123123 ", "+48123123123"]
      })
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("ignored_field", "ignored")

    assert {:ok, rule} = Rules.create(attrs)
    assert rule.source_id == "42"
    assert rule.email_recipients == ["Ops@example.test"]
    assert rule.sms_recipients == ["+48123123123"]
  end

  test "recipients are normalized to provider-ready text and phones are deduplicated as E.164" do
    email = connection!("smtp", %{host: "smtp.example.test"})
    sms = connection!("smsapi", %{sender: "Harmony"})

    attrs =
      rule_attrs()
      |> Map.merge(%{
        email_connection_id: email.id,
        email_recipients: [123],
        sms_connection_id: sms.id,
        sms_recipients: ["+48 123 123 123", "0048123123123", "+48-123-(123)-123", "+48 600 100 200"]
      })

    assert {:ok, rule} = Rules.create(attrs)
    assert rule.email_recipients == ["123"]
    assert rule.sms_recipients == ["+48123123123", "+48600100200"]

    assert {:ok, patched} = Rules.patch(rule, %{sms_recipients: ["+48 600 100 200", "+48600100200"]})
    assert patched.sms_recipients == ["+48600100200"]
  end

  test "phone recipients without an international prefix are rejected instead of dropped" do
    sms = connection!("smsapi", %{sender: "Harmony"})
    attrs = Map.merge(rule_attrs(), %{sms_connection_id: sms.id})

    for invalid <- [[48_123_123_123], ["48123123123"], ["+48 123 123 123", "not-a-phone"], ["+0123456789"]] do
      assert {:error, changeset} = Rules.create(%{attrs | sms_recipients: invalid})
      assert {"must contain E.164 phone numbers", _meta} = changeset.errors[:sms_recipients]
    end

    assert {:ok, rule} = Rules.create(%{attrs | sms_recipients: ["+48123123123"]})
    assert {:error, changeset} = Rules.patch(rule, %{sms_recipients: ["600100200"]})
    assert {"must contain E.164 phone numbers", _meta} = changeset.errors[:sms_recipients]
    assert Repo.get!(AutomationRule, rule.id).sms_recipients == ["+48123123123"]
  end

  test "a missing referenced connection is rejected by the foreign key" do
    assert {:error, changeset} = Rules.create(%{rule_attrs() | jira_connection_id: Ecto.UUID.generate()})
    assert Keyword.has_key?(changeset.errors, :jira_connection)
  end

  test "recipient limits and a missing delivery connection are rejected" do
    email = connection!("smtp", %{host: "smtp.example.test"})
    attrs = rule_attrs()

    too_many_recipients =
      Map.merge(attrs, %{
        email_connection_id: email.id,
        email_recipients: Enum.map(1..11, &"ops#{&1}@example.test")
      })

    assert {:error, changeset} = Rules.create(too_many_recipients)
    assert Keyword.has_key?(changeset.errors, :email_recipients)

    without_connection = Map.merge(attrs, %{email_recipients: ["ops@example.test"]})
    assert {:error, changeset} = Rules.create(without_connection)
    assert Keyword.has_key?(changeset.errors, :email_connection_id)
  end

  test "SMS recipients require their provider and source type changes reset the baseline" do
    attrs = rule_attrs()
    sms = connection!("smsapi", %{sender: "Harmony"})

    assert {:error, missing_recipients} =
             Rules.create(Map.merge(attrs, %{sms_connection_id: sms.id, sms_recipients: []}))

    assert Keyword.has_key?(missing_recipients.errors, :sms_recipients)

    assert {:error, missing_connection} =
             Rules.create(Map.merge(attrs, %{sms_recipients: ["+48123123123"]}))

    assert Keyword.has_key?(missing_connection.errors, :sms_connection_id)

    assert {:ok, rule} = Rules.create(attrs)
    assert {:ok, active} = Rules.activate(rule)
    refute active.enabled
    assert active.activation_status == "activating"
    assert {:ok, filtered} = Rules.patch(active, %{source_type: "filter"})
    refute filtered.enabled
    assert filtered.source_type == "filter"
    assert is_nil(filtered.baseline_generation)
    assert is_nil(filtered.baseline_complete_at)
    assert filtered.config_version == active.config_version + 1
  end

  test "snapshot leaves optional destinations empty and PATCH preserves an active rule on display edits" do
    assert {:ok, rule} = Rules.create(rule_attrs())
    snapshot = Rules.snapshot(rule)
    assert is_nil(snapshot.email_connection_id)
    assert is_nil(snapshot.email_connection_name)
    assert is_nil(snapshot.sms_connection_id)
    assert is_nil(snapshot.sms_connection_name)

    assert {:ok, active} = Rules.activate(rule)
    assert {:ok, renamed} = Rules.patch(active, %{"name" => "Renamed via string key"})
    assert renamed.name == "Renamed via string key"
    refute renamed.enabled
    assert renamed.activation_status == "activating"
    assert renamed.config_version == active.config_version + 1
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

  test "snapshot names the project by its display name and falls back to the slug" do
    assert {:ok, rule} = Rules.create(rule_attrs())
    project = Repo.get!(Project, rule.project_id)
    assert Rules.snapshot(rule).project_name == project.slug

    project |> Project.changeset(%{display_name: "Finanse"}) |> Repo.update!()
    assert Rules.snapshot(rule).project_name == "Finanse"
  end

  test "changing source disables an active rule and target fields stay immutable" do
    assert {:ok, rule} = Rules.create(rule_attrs())
    assert {:ok, active} = Rules.activate(rule)
    refute active.enabled
    assert active.activation_status == "activating"
    assert active.activated_at

    assert {:error, :immutable_after_activation} =
             Rules.patch(active, %{linear_project_id: "other-project"})

    assert {:ok, disabled} = Rules.patch(active, %{source_id: "99"})
    refute disabled.enabled
    assert disabled.activation_status == "idle"
    assert disabled.config_version == active.config_version + 1
  end

  test "changing priority IDs disables an active rule for a new baseline" do
    assert {:ok, rule} = Rules.create(rule_attrs())
    assert {:ok, active} = Rules.activate(rule)

    assert {:ok, disabled} = Rules.patch(active, %{priority_ids: ["2"]})
    refute disabled.enabled
    assert disabled.activation_status == "idle"
    assert is_nil(disabled.baseline_generation)
    assert disabled.config_version == active.config_version + 1
  end

  test "a Jira URL cannot change while a case references its connection" do
    case_connection = connection!("jira_cloud", %{site_url: "https://case-jira.example.test"})
    assert {:ok, rule} = Rules.create(rule_attrs())
    time = now()

    %IntakeCase{}
    |> IntakeCase.changeset(%{
      project_id: rule.project_id,
      rule_id: rule.id,
      jira_connection_id: case_connection.id,
      jira_issue_id: "case-#{System.unique_integer([:positive])}",
      jira_key: "OPS-1",
      jira_url: "https://case-jira.example.test/browse/OPS-1",
      title: "Case",
      description_text: "Description",
      priority_id: "1",
      priority_name: "P1",
      jira_updated_at: time,
      detected_at: time,
      rule_snapshot: %{},
      analysis_version: 1,
      analysis_status: "queued",
      lock_version: 1
    })
    |> Repo.insert!()

    assert Connections.site_url(%IntegrationConnection{settings: %{site_url: "https://atom-key.example.test"}}) ==
             "https://atom-key.example.test"

    assert {:error, changeset} =
             Connections.update(case_connection, %{settings: %{site_url: "https://replacement.example.test"}})

    assert Keyword.has_key?(changeset.errors, :site_url)
  end

  test "a rule remains active during its activation transition" do
    rule = %AutomationRule{enabled: false, activation_status: "activating"}
    assert Rules.active?(rule)
  end

  test "effects kill switch blocks rule activation" do
    assert {:ok, rule} = Rules.create(rule_attrs())

    write_workflow_file!(Workflow.workflow_file_path(),
      intake_enabled: true,
      intake_effects_enabled: false,
      intake_public_url: "https://harmony.example.test"
    )

    assert {:error, :effects_disabled} = Rules.activate(rule)

    stored_rule = Repo.get!(AutomationRule, rule.id)
    refute stored_rule.enabled
    assert stored_rule.activation_status == "idle"
    assert is_nil(stored_rule.activated_at)
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
