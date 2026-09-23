defmodule SymphonyElixir.IntakeLinearBridgeTest do
  use SymphonyElixir.TestSupport

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake.ExecutionGate
  alias SymphonyElixir.Intake.LinearBridge
  alias SymphonyElixir.Intake.Outbox
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{AutomationRule, IntakeCase, IntegrationConnection, IntegrationDelivery, Project}
  alias SymphonyElixir.WorkSources.LinearIssueSource

  @fixture_root Path.expand("../fixtures/intake", __DIR__)
  @team_id "11111111-1111-4111-8111-111111111111"
  @project_id "22222222-2222-4222-8222-222222222222"
  @todo_id "33333333-3333-4333-8333-333333333333"
  @label_id "44444444-4444-4444-8444-444444444444"
  @token "project-linear-token"

  setup do
    :ok = Sandbox.checkout(Repo)

    {:ok, provider} =
      Agent.start_link(fn ->
        %{
          issues: %{},
          inputs: [],
          requests: [],
          create_mode: :success,
          create_modes: [],
          lookup_mode: :missing
        }
      end)

    %{provider: provider}
  end

  test "the checked Linear schema contract accepts a caller-reserved create UUID" do
    schema = File.read!(Path.join(@fixture_root, "linear_schema.graphql"))

    assert Regex.match?(~r/input IssueCreateInput\s*\{(?s:.*?)\bid:\s*String\b/, schema)
    assert schema =~ "issue(id: String!): Issue!"
    assert schema =~ "id: IssueIDComparator"
    assert schema =~ "eq: ID"
    assert schema =~ "issues(filter: IssueFilter, first: Int): IssueConnection!"
    assert schema =~ "issueCreate"
  end

  test "non-null issue not-found error needs a successful empty ID filter before create", %{provider: provider} do
    project = project!()
    {intake_case, delivery, _rule} = case_and_delivery!(project)

    assert {:ok, %{provider_id: id}} =
             LinearBridge.perform(delivery,
               token: @token,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    assert id == intake_case.linear_issue_id
    assert provider_requests(provider) == [:lookup, :lookup_fallback, :create]
    assert length(create_inputs(provider)) == 1
    assert_direct_lookup!(provider, intake_case)
    assert_filter_lookup!(provider, intake_case)
  end

  test "authentication errors fail closed even if the fallback lookup would be empty", %{provider: provider} do
    for lookup_mode <- [:direct_auth_filter_empty, :fallback_authentication_error] do
      Agent.update(provider, fn _state ->
        %{issues: %{}, inputs: [], requests: [], create_mode: :success, lookup_mode: lookup_mode}
      end)

      project = project!()
      {intake_case, delivery, _rule} = case_and_delivery!(project)

      assert {:unknown, "linear_graphql_errors"} =
               LinearBridge.perform(delivery,
                 token: @token,
                 request_fun: provider_request_fun(self(), provider, intake_case)
               )

      expected_requests =
        if lookup_mode == :direct_auth_filter_empty do
          [:lookup]
        else
          [:lookup, :lookup_fallback]
        end

      assert provider_requests(provider) == expected_requests
      assert create_inputs(provider) == []
    end
  end

  test "malformed direct lookup responses fail closed without trying the filter or create", %{provider: provider} do
    project = project!()
    {intake_case, delivery, _rule} = case_and_delivery!(project)
    Agent.update(provider, &Map.put(&1, :lookup_mode, :malformed_direct))

    assert {:unknown, "linear_unknown_payload"} =
             LinearBridge.perform(delivery,
               token: @token,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    assert provider_requests(provider) == [:lookup]
    assert create_inputs(provider) == []
    assert is_nil(Repo.get!(IntakeCase, intake_case.id).linear_confirmed_at)
  end

  test "global Linear token is the documented fallback when the project token is cleared", %{provider: provider} do
    project = project!()
    {:ok, project} = SymphonyElixir.Storage.update_project_secrets(project, %{"clear_tracker_secret" => "true"})
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "global-linear-token")
    {intake_case, delivery, _rule} = case_and_delivery!(project)

    assert {:ok, _confirmed} =
             LinearBridge.perform(delivery,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    assert_received {:linear_request, "SymphonyLinearIntakeIssueById", _payload, headers}
    assert {"Authorization", "global-linear-token"} = List.keyfind(headers, "Authorization", 0)
  end

  test "missing project and global Linear tokens stop before any provider request", %{provider: provider} do
    project = project!()
    {:ok, project} = SymphonyElixir.Storage.update_project_secrets(project, %{"clear_tracker_secret" => "true"})
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    {intake_case, delivery, _rule} = case_and_delivery!(project)

    assert {:error, "missing_linear_api_token"} =
             LinearBridge.perform(delivery,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    assert provider_requests(provider) == []
    assert create_inputs(provider) == []
  end

  test "a timeout after provider persistence is reconciled by reserved UUID and retry creates once", %{provider: provider} do
    project = project!()
    {intake_case, delivery, _rule} = case_and_delivery!(project)
    Agent.update(provider, &Map.put(&1, :create_mode, :timeout_after_create))
    request_fun = provider_request_fun(self(), provider, intake_case)

    assert {:ok, %{provider_id: provider_id}} =
             LinearBridge.perform(delivery, token: @token, request_fun: request_fun)

    assert {:ok, %{provider_id: ^provider_id}} =
             LinearBridge.perform(delivery, token: @token, request_fun: request_fun)

    assert provider_id == intake_case.linear_issue_id
    assert provider_requests(provider) == [:lookup, :lookup_fallback, :create, :lookup, :lookup]
    assert length(create_inputs(provider)) == 1
    assert_confirmed!(intake_case, "OPS-42", "https://linear.app/harmony/issue/OPS-42")
    assert_create_input!(create_inputs(provider) |> hd(), intake_case)

    assert_direct_lookup!(provider, intake_case)
  end

  test "confirmed absence allows a same-UUID retry after transient create failures", %{provider: provider} do
    for failure_mode <- [:timeout_without_create, {:status_without_create, 429}, {:status_without_create, 503}] do
      reset_provider!(provider, create_modes: [failure_mode, :success])
      project = project!()
      {intake_case, delivery, _rule} = case_and_delivery!(project)

      assert {:ok, %{provider_id: id}} =
               LinearBridge.perform(delivery,
                 token: @token,
                 request_fun: provider_request_fun(self(), provider, intake_case)
               )

      assert id == intake_case.linear_issue_id

      assert provider_requests(provider) == [
               :lookup,
               :lookup_fallback,
               :create,
               :lookup,
               :lookup_fallback,
               :create
             ]

      assert [first_input, second_input] = create_inputs(provider)
      assert first_input == second_input
      assert first_input[:id] == intake_case.linear_issue_id
      assert_confirmed!(intake_case, "OPS-42", "https://linear.app/harmony/issue/OPS-42")
    end
  end

  test "a second lost response is recovered by UUID without a third create", %{provider: provider} do
    reset_provider!(provider, create_modes: [:timeout_without_create, :timeout_after_create])
    project = project!()
    {intake_case, delivery, _rule} = case_and_delivery!(project)

    assert {:ok, %{provider_id: id}} =
             LinearBridge.perform(delivery,
               token: @token,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    assert id == intake_case.linear_issue_id

    assert provider_requests(provider) == [
             :lookup,
             :lookup_fallback,
             :create,
             :lookup,
             :lookup_fallback,
             :create,
             :lookup
           ]

    assert [first_input, second_input] = create_inputs(provider)
    assert first_input == second_input
    assert first_input[:id] == intake_case.linear_issue_id
    assert_confirmed!(intake_case, "OPS-42", "https://linear.app/harmony/issue/OPS-42")
  end

  test "two retryable failures with certain absence remain unknown and never create a third issue", %{
    provider: provider
  } do
    reset_provider!(provider, create_modes: [:timeout_without_create, :timeout_without_create])
    project = project!()
    {intake_case, delivery, _rule} = case_and_delivery!(project)

    assert {:unknown, "linear_transport_error"} =
             LinearBridge.perform(delivery,
               token: @token,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    assert provider_requests(provider) == [
             :lookup,
             :lookup_fallback,
             :create,
             :lookup,
             :lookup_fallback,
             :create,
             :lookup,
             :lookup_fallback
           ]

    assert [first_input, second_input] = create_inputs(provider)
    assert first_input == second_input
    assert first_input[:id] == intake_case.linear_issue_id
    assert is_nil(Repo.get!(IntakeCase, intake_case.id).linear_confirmed_at)
  end

  test "a successful HTTP response with success false never confirms the issue", %{provider: provider} do
    project = project!()
    {intake_case, delivery, _rule} = case_and_delivery!(project)
    Agent.update(provider, &Map.put(&1, :create_mode, :unsuccessful_without_create))

    assert {:error, "linear_create_unsuccessful"} =
             LinearBridge.perform(delivery,
               token: @token,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    assert provider_requests(provider) == [
             :lookup,
             :lookup_fallback,
             :create,
             :lookup,
             :lookup_fallback
           ]

    assert length(create_inputs(provider)) == 1
    assert is_nil(Repo.get!(IntakeCase, intake_case.id).linear_confirmed_at)
  end

  test "a UUID conflict is followed by a lookup and adopts only the matching protected issue", %{provider: provider} do
    project = project!()
    {intake_case, delivery, _rule} = case_and_delivery!(project)
    Agent.update(provider, &Map.put(&1, :create_mode, :conflict_after_create))

    assert {:ok, %{provider_id: id}} =
             LinearBridge.perform(delivery,
               token: @token,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    assert id == intake_case.linear_issue_id
    assert provider_requests(provider) == [:lookup, :lookup_fallback, :create, :lookup]
    assert length(create_inputs(provider)) == 1
    assert_confirmed!(intake_case, "OPS-42", "https://linear.app/harmony/issue/OPS-42")
  end

  test "an existing issue stays idempotent when Harmony public URL changes", %{provider: provider} do
    project = project!()
    {intake_case, delivery, _rule} = case_and_delivery!(project)
    Agent.update(provider, &put_in(&1, [:issues, intake_case.linear_issue_id], issue_fixture(intake_case)))
    write_intake_public_url!("https://new-harmony.example.test")

    assert {:ok, %{provider_id: id}} =
             LinearBridge.perform(delivery,
               token: @token,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    assert id == intake_case.linear_issue_id
    assert provider_requests(provider) == [:lookup]
    assert create_inputs(provider) == []
    assert_confirmed!(intake_case, "OPS-42", "https://linear.app/harmony/issue/OPS-42")
  end

  test "a process crash after Linear create is recovered by lookup before another create", %{provider: provider} do
    project = project!()
    {intake_case, delivery, _rule} = case_and_delivery!(project)
    Agent.update(provider, &Map.put(&1, :create_mode, :crash_after_create))
    parent = self()
    request_fun = provider_request_fun(parent, provider, intake_case)

    {pid, ref} =
      spawn_monitor(fn ->
        receive do
          :start -> LinearBridge.perform(delivery, token: @token, request_fun: request_fun)
        end
      end)

    :ok = Sandbox.allow(Repo, self(), pid)
    send(pid, :start)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

    assert {:ok, %{provider_id: id}} =
             LinearBridge.perform(delivery,
               token: @token,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    assert id == intake_case.linear_issue_id
    assert provider_requests(provider) == [:lookup, :lookup_fallback, :create, :lookup]
    assert length(create_inputs(provider)) == 1
    assert_confirmed!(intake_case, "OPS-42", "https://linear.app/harmony/issue/OPS-42")
  end

  test "a Linear poll during create remains denied by the execution gate", %{provider: provider} do
    project = project!()
    {intake_case, delivery, _rule} = case_and_delivery!(project)
    parent = self()

    on_created = fn ->
      poll_fun = fn payload, headers -> provider_poll_response(provider, payload, headers) end

      assert {:ok, []} =
               LinearIssueSource.fetch_candidates(
                 project_id: project.id,
                 project_slug: project.slug,
                 linear_project_slug: "harmony-intake",
                 token: @token,
                 request_fun: poll_fun,
                 execution_gate_fun: fn issue, project_id ->
                   result = ExecutionGate.authorize_implementation(issue, project_id)
                   send(parent, {:gate_result_during_create, result})
                   result
                 end
               )
    end

    assert {:ok, _created} =
             LinearBridge.perform(delivery,
               token: @token,
               request_fun: provider_request_fun(parent, provider, intake_case, on_created: on_created)
             )

    assert_received {:gate_result_during_create, {:error, :analysis_only}}
  end

  test "missing Todo or the protective label prevents lookup and create", %{provider: provider} do
    for missing_target <- [:linear_todo_state_id, :linear_hold_label_id] do
      project = project!()

      snapshot = %{
        linear_team_id: @team_id,
        linear_project_id: @project_id,
        linear_todo_state_id: if(missing_target == :linear_todo_state_id, do: nil, else: @todo_id),
        linear_hold_label_id: if(missing_target == :linear_hold_label_id, do: nil, else: @label_id)
      }

      {intake_case, delivery, _rule} = case_and_delivery!(project, snapshot: snapshot)

      assert {:error, "linear_target_configuration_incomplete"} =
               LinearBridge.perform(delivery,
                 token: @token,
                 request_fun: provider_request_fun(self(), provider, intake_case)
               )
    end

    assert provider_requests(provider) == []
    assert create_inputs(provider) == []
  end

  test "routing IDs must be UUIDs before any Linear request", %{provider: provider} do
    for key <- [:linear_team_id, :linear_project_id, :linear_todo_state_id, :linear_hold_label_id] do
      project = project!()
      snapshot = Map.put(target_snapshot(), key, "not-a-uuid")
      {intake_case, delivery, _rule} = case_and_delivery!(project, snapshot: snapshot)

      assert {:error, "linear_target_configuration_invalid"} =
               LinearBridge.perform(delivery,
                 token: @token,
                 request_fun: provider_request_fun(self(), provider, intake_case)
               )
    end

    assert provider_requests(provider) == []
    assert create_inputs(provider) == []
  end

  test "an absent Harmony public URL fails before lookup or create", %{provider: provider} do
    project = project!()
    {intake_case, delivery, _rule} = case_and_delivery!(project)
    write_intake_public_url!(nil)

    assert {:error, "missing_intake_public_url"} =
             LinearBridge.perform(delivery,
               token: @token,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    assert provider_requests(provider) == []
    assert create_inputs(provider) == []
  end

  test "HTTP 200 GraphQL errors keep analysis blocked until Linear is confirmed", %{provider: provider} do
    project = project!()
    {intake_case, delivery, _rule} = case_and_delivery!(project)
    analysis_delivery = analysis_delivery!(intake_case)
    Agent.update(provider, &Map.put(&1, :create_mode, :graphql_error_without_create))

    assert {:unknown, "linear_graphql_errors"} =
             LinearBridge.perform(delivery,
               token: @token,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    stored = Repo.get!(IntakeCase, intake_case.id)
    assert is_nil(stored.linear_confirmed_at)
    assert is_nil(stored.linear_identifier)
    assert provider_requests(provider) == [:lookup, :lookup_fallback, :create, :lookup, :lookup_fallback]
    assert length(create_inputs(provider)) == 1

    claim_opts = [
      operation: "analysis",
      intake_enabled: true,
      effects_enabled: false,
      analysis_enabled: true,
      now: DateTime.utc_now()
    ]

    assert :empty = Outbox.claim(claim_opts)
    assert Repo.reload!(analysis_delivery).status == "pending"

    Agent.update(provider, &Map.put(&1, :create_mode, :success))

    assert {:ok, _confirmed} =
             LinearBridge.perform(delivery,
               token: @token,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    assert {:ok, claimed_analysis} = Outbox.claim(claim_opts)
    assert claimed_analysis.id == analysis_delivery.id
  end

  test "existing issues must match target project, team, Todo state, and protective label", %{provider: provider} do
    mismatches = [
      ["project", "id"],
      ["team", "id"],
      ["state", "id"],
      ["labels", "nodes", 0, "id"]
    ]

    for path <- mismatches do
      project = project!()
      {intake_case, delivery, _rule} = case_and_delivery!(project)
      valid_issue = issue_fixture(intake_case)
      raw_issue = get_in(valid_issue, ["data", "issue"])
      mismatched_issue = replace_path(raw_issue, path, "wrong-target-id")
      mismatched_response = put_in(valid_issue, ["data", "issue"], mismatched_issue)
      Agent.update(provider, &put_in(&1, [:issues, intake_case.linear_issue_id], mismatched_response))

      assert {:unknown, "linear_issue_identity_mismatch"} =
               LinearBridge.perform(delivery,
                 token: @token,
                 request_fun: provider_request_fun(self(), provider, intake_case)
               )

      assert is_nil(Repo.get!(IntakeCase, intake_case.id).linear_confirmed_at)
    end

    assert provider_requests(provider) == List.duplicate(:lookup, length(mismatches))
    assert create_inputs(provider) == []
  end

  test "an issue without Harmony case markers is not adopted by its reserved UUID", %{provider: provider} do
    project = project!()
    {intake_case, delivery, _rule} = case_and_delivery!(project)
    issue = put_in(issue_fixture(intake_case), ["data", "issue", "description"], "Unrelated issue")
    Agent.update(provider, &put_in(&1, [:issues, intake_case.linear_issue_id], issue))

    assert {:unknown, "linear_issue_identity_mismatch"} =
             LinearBridge.perform(delivery,
               token: @token,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    assert provider_requests(provider) == [:lookup]
    assert create_inputs(provider) == []
    assert is_nil(Repo.get!(IntakeCase, intake_case.id).linear_confirmed_at)
  end

  test "a changed reserved UUID during confirmation cannot persist a stale provider link", %{provider: provider} do
    project = project!()
    {intake_case, delivery, _rule} = case_and_delivery!(project)
    Agent.update(provider, &put_in(&1, [:issues, intake_case.linear_issue_id], issue_fixture(intake_case)))
    provider_request = provider_request_fun(self(), provider, intake_case)

    request_fun = fn payload, headers ->
      response = provider_request.(payload, headers)

      if payload["operationName"] == "SymphonyLinearIntakeIssueById" do
        current_case = Repo.get!(IntakeCase, intake_case.id)

        current_case
        |> IntakeCase.changeset(%{linear_issue_id: Ecto.UUID.generate()})
        |> Repo.update!()
      end

      response
    end

    assert {:unknown, "linear_confirmation_persistence_failed"} =
             LinearBridge.perform(delivery, token: @token, request_fun: request_fun)

    stored = Repo.get!(IntakeCase, intake_case.id)
    assert stored.linear_issue_id != intake_case.linear_issue_id
    assert is_nil(stored.linear_confirmed_at)
    assert is_nil(stored.linear_identifier)
    assert create_inputs(provider) == []
  end

  test "string-key target snapshots are accepted for issue creation", %{provider: provider} do
    project = project!()
    snapshot = Map.new(target_snapshot(), fn {key, value} -> {Atom.to_string(key), value} end)
    {intake_case, delivery, _rule} = case_and_delivery!(project, snapshot: snapshot)

    assert {:ok, %{provider_id: id}} =
             LinearBridge.perform(delivery,
               token: @token,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    assert id == intake_case.linear_issue_id
    assert provider_requests(provider) == [:lookup, :lookup_fallback, :create]
    assert_confirmed!(intake_case, "OPS-42", "https://linear.app/harmony/issue/OPS-42")
  end

  test "stale outbox UUID metadata fails before any Linear request", %{provider: provider} do
    project = project!()
    {intake_case, delivery, _rule} = case_and_delivery!(project)
    stale_delivery = %{delivery | payload: %{"linear_issue_id" => Ecto.UUID.generate()}}

    assert {:error, "linear_reserved_uuid_mismatch"} =
             LinearBridge.perform(stale_delivery,
               token: @token,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    assert provider_requests(provider) == []
    assert create_inputs(provider) == []
  end

  test "create carries the reserved UUID, exact routing IDs, safe title, markers, and no priority or assignee",
       %{provider: provider} do
    project = project!()
    description = String.duplicate("界é ", 80)

    {intake_case, delivery, _rule} =
      case_and_delivery!(project, title: String.duplicate("Á", 300), description_text: description)

    assert {:ok, %{provider_id: _id}} =
             LinearBridge.perform(delivery,
               token: @token,
               request_fun: provider_request_fun(self(), provider, intake_case)
             )

    [input] = create_inputs(provider)
    assert_create_input!(input, intake_case)
    assert String.length(input.title) <= 255
    assert input.title =~ "[OPS-42] "
    assert input.description =~ intake_case.jira_url
    assert input.description =~ "Harmony case: #{intake_case.id}"
    assert input.description =~ "Tylko analiza"
    assert input.description =~ "https://harmony.example.test/cases/jira_#{intake_case.id}"
    assert input.description =~ description
    refute Map.has_key?(input, :priority)
    refute Map.has_key?(input, :assigneeId)
    refute Map.has_key?(input, :dueDate)

    assert provider_requests(provider) == [:lookup, :lookup_fallback, :create]
    assert_receive {:linear_request, "SymphonyLinearIntakeIssueById", _payload, headers}
    assert {"Authorization", @token} = List.keyfind(headers, "Authorization", 0)
  end

  defp project! do
    project =
      %Project{}
      |> Project.changeset(%{
        slug: "intake-linear-#{System.unique_integer([:positive])}",
        linear_project_slug: "harmony-intake",
        linear_team_key: "OPS",
        forge_owner: "example",
        forge_repo: "harmony",
        forge_base_branch: "main",
        config_version: 1,
        config: %{}
      })
      |> Repo.insert!()

    {:ok, project} = SymphonyElixir.Storage.update_project_secrets(project, %{"tracker_secret" => @token})
    project
  end

  defp case_and_delivery!(project, opts \\ []) do
    write_intake_public_url!("https://harmony.example.test")

    connection =
      %IntegrationConnection{}
      |> IntegrationConnection.changeset(%{
        kind: "jira_cloud",
        name: "Intake Linear Bridge Jira",
        settings: %{site_url: "https://intake-linear-#{System.unique_integer([:positive])}.atlassian.net"},
        secret: "jira-token",
        enabled: true
      })
      |> Repo.insert!()

    rule =
      %AutomationRule{}
      |> AutomationRule.changeset(%{
        project_id: project.id,
        jira_connection_id: connection.id,
        name: "Linear bridge rule",
        source_type: "board",
        source_id: "42",
        priority_ids: ["1"],
        interval_seconds: 300,
        initial_policy: "new_matches_only",
        linear_team_id: @team_id,
        linear_project_id: @project_id,
        linear_todo_state_id: @todo_id,
        linear_hold_label_id: @label_id,
        email_recipients: [],
        sms_recipients: []
      })
      |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    snapshot = Keyword.get(opts, :snapshot, target_snapshot())

    intake_case =
      %IntakeCase{}
      |> IntakeCase.changeset(%{
        project_id: project.id,
        rule_id: rule.id,
        jira_connection_id: connection.id,
        jira_issue_id: "10042",
        jira_key: "OPS-42",
        jira_url: "https://example.atlassian.net/browse/OPS-42",
        title: Keyword.get(opts, :title, "Imported issue"),
        description_text: Keyword.get(opts, :description_text, "Source Jira description"),
        priority_id: "1",
        priority_name: "Highest",
        jira_updated_at: now,
        detected_at: now,
        rule_snapshot: snapshot,
        linear_issue_id: Ecto.UUID.generate(),
        analysis_version: 1,
        analysis_status: "queued",
        lock_version: 1
      })
      |> Repo.insert!()

    delivery =
      %IntegrationDelivery{}
      |> IntegrationDelivery.changeset(%{
        case_id: intake_case.id,
        operation: "linear_create",
        dedupe_key: "case:#{intake_case.id}:linear:v1",
        payload: %{"linear_issue_id" => intake_case.linear_issue_id, "case_ref" => "jira_#{intake_case.id}", "jira_key" => intake_case.jira_key},
        status: "pending",
        attempts: 0,
        next_attempt_at: now,
        lock_version: 1
      })
      |> Repo.insert!()

    {intake_case, delivery, rule}
  end

  defp write_intake_public_url!(url) do
    path = Workflow.workflow_file_path()
    contents = File.read!(path)
    [front_matter, body] = String.split(contents, "\n---\n", parts: 2)
    front_matter = Regex.replace(~r/\nintake:\n(?:[ \t]+[^\n]*(?:\n|$))*/, front_matter, "")
    value = if is_binary(url), do: "\"#{url}\"", else: "null"
    front_matter = String.trim_trailing(front_matter) <> "\nintake:\n  public_url: #{value}"
    File.write!(path, front_matter <> "\n---\n" <> body)
    WorkflowStore.force_reload()
  end

  defp analysis_delivery!(intake_case) do
    %IntegrationDelivery{}
    |> IntegrationDelivery.changeset(%{
      case_id: intake_case.id,
      operation: "analysis",
      dedupe_key: "case:#{intake_case.id}:analysis:v1",
      payload: %{"version" => 1},
      status: "pending",
      attempts: 0,
      next_attempt_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      lock_version: 1
    })
    |> Repo.insert!()
  end

  defp target_snapshot do
    %{
      linear_team_id: @team_id,
      linear_project_id: @project_id,
      linear_todo_state_id: @todo_id,
      linear_hold_label_id: @label_id
    }
  end

  defp provider_request_fun(parent, provider, intake_case, opts \\ []) do
    fn payload, headers ->
      operation = payload["operationName"]
      send(parent, {:linear_request, operation, payload, headers})
      Agent.update(provider, &Map.update!(&1, :requests, fn requests -> requests ++ [{:raw, operation, payload}] end))
      provider_response(operation, payload, provider, intake_case, opts)
    end
  end

  defp provider_response("SymphonyLinearIntakeIssueById", _payload, provider, intake_case, _opts),
    do: direct_lookup_response(provider, intake_case)

  defp provider_response("SymphonyLinearIssuesById", _payload, provider, intake_case, _opts),
    do: filter_lookup_response(provider, intake_case)

  defp provider_response("SymphonyLinearIntakeIssueCreate", payload, provider, intake_case, opts),
    do: create_issue_response(payload, provider, intake_case, opts)

  defp provider_response(_operation, _payload, _provider, _intake_case, _opts),
    do: {:error, :unexpected_linear_request}

  defp direct_lookup_response(provider, intake_case) do
    case Agent.get(provider, & &1.lookup_mode) do
      mode when mode in [:authentication_error, :direct_auth_filter_empty] ->
        {:ok, %{status: 200, body: fixture("linear_issue_lookup_auth_error.json", %{})}}

      :malformed_direct ->
        {:ok, %{status: 200, body: %{"data" => %{"issue" => []}}}}

      _lookup_mode ->
        direct_lookup_for_issue(provider, intake_case)
    end
  end

  defp direct_lookup_for_issue(provider, intake_case) do
    case provider_issue(provider, intake_case) do
      nil -> {:ok, %{status: 200, body: fixture("linear_issue_lookup_missing.json", %{})}}
      issue_response -> {:ok, %{status: 200, body: issue_response}}
    end
  end

  defp filter_lookup_response(provider, intake_case) do
    case Agent.get(provider, & &1.lookup_mode) do
      mode when mode in [:authentication_error, :fallback_authentication_error] ->
        body = fixture("linear_issue_lookup_auth_error.json", %{})
        body = put_in(body, ["errors", Access.at(0), "path"], ["issues"])
        {:ok, %{status: 200, body: body}}

      _lookup_mode ->
        filter_lookup_for_issue(provider, intake_case)
    end
  end

  defp filter_lookup_for_issue(provider, intake_case) do
    case provider_issue(provider, intake_case) do
      nil ->
        {:ok, %{status: 200, body: fixture("linear_issue_lookup_empty.json", %{})}}

      issue_response ->
        issue = get_in(issue_response, ["data", "issue"])
        body = %{"data" => %{"issues" => %{"nodes" => [issue]}}}
        {:ok, %{status: 200, body: body}}
    end
  end

  defp provider_issue(provider, intake_case) do
    Agent.get(provider, &get_in(&1, [:issues, intake_case.linear_issue_id]))
  end

  defp create_issue_response(payload, provider, intake_case, opts) do
    input = payload["variables"][:input]
    Agent.update(provider, &Map.update!(&1, :inputs, fn inputs -> inputs ++ [input] end))

    mode = next_create_mode(provider)
    issue_response = issue_fixture(intake_case)
    maybe_persist_issue(provider, intake_case, issue_response, mode)

    cond do
      mode == :crash_after_create ->
        Process.exit(self(), :kill)

      mode == :timeout_after_create ->
        {:error, :timeout}

      mode == :timeout_without_create ->
        {:error, :timeout}

      true ->
        run_create_callback(opts)
        create_mode_response(mode, intake_case)
    end
  end

  defp maybe_persist_issue(provider, intake_case, issue_response, mode)
       when mode in [:success, :timeout_after_create, :conflict_after_create, :crash_after_create] do
    Agent.update(provider, &put_in(&1, [:issues, intake_case.linear_issue_id], issue_response))
  end

  defp maybe_persist_issue(_provider, _intake_case, _issue_response, _mode), do: :ok

  defp next_create_mode(provider) do
    Agent.get_and_update(provider, fn state ->
      case state.create_modes do
        [mode | rest] -> {mode, %{state | create_modes: rest}}
        [] -> {state.create_mode, state}
      end
    end)
  end

  defp reset_provider!(provider, opts) do
    Agent.update(provider, fn _state ->
      %{
        issues: %{},
        inputs: [],
        requests: [],
        create_mode: :success,
        create_modes: Keyword.get(opts, :create_modes, []),
        lookup_mode: :missing
      }
    end)
  end

  defp run_create_callback(opts) do
    if is_function(Keyword.get(opts, :on_created), 0), do: Keyword.fetch!(opts, :on_created).()
  end

  defp create_mode_response(:success, intake_case) do
    {:ok, %{status: 200, body: fixture("linear_issue_create_success.json", issue_values(intake_case))}}
  end

  defp create_mode_response(:conflict_after_create, _intake_case) do
    {:ok, %{status: 200, body: %{"errors" => [%{"message" => "ID already exists"}]}}}
  end

  defp create_mode_response(:graphql_error_without_create, _intake_case) do
    {:ok, %{status: 200, body: %{"errors" => [%{"message" => "create rejected"}]}}}
  end

  defp create_mode_response({:status_without_create, status}, _intake_case) do
    {:ok, %{status: status, body: %{}}}
  end

  defp create_mode_response(:unsuccessful_without_create, _intake_case) do
    {:ok,
     %{
       status: 200,
       body: %{"data" => %{"issueCreate" => %{"success" => false, "issue" => nil}}}
     }}
  end

  defp provider_poll_response(provider, payload, headers) do
    case Agent.get(provider, & &1.issues) |> Map.values() do
      [issue_response | _] ->
        issue = get_in(issue_response, ["data", "issue"])

        response = %{
          "data" => %{
            "issues" => %{
              "nodes" => [issue],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }

        send(self(), {:poll_request_seen, payload["operationName"], headers})
        {:ok, %{status: 200, body: response}}

      [] ->
        {:ok, %{status: 200, body: %{"data" => %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}}
    end
  end

  defp issue_fixture(intake_case) do
    fixture("linear_issue_lookup_found.json", issue_values(intake_case))
  end

  defp issue_values(intake_case) do
    %{
      "__ISSUE_ID__" => intake_case.linear_issue_id,
      "__CASE_ID__" => intake_case.id,
      "__CASE_URL__" => "https://harmony.example.test/cases/jira_#{intake_case.id}",
      "__TEAM_ID__" => @team_id,
      "__PROJECT_ID__" => @project_id,
      "__STATE_ID__" => @todo_id,
      "__LABEL_ID__" => @label_id
    }
  end

  defp fixture(name, replacements) do
    @fixture_root
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
    |> replace_values(replacements)
  end

  defp replace_values(value, replacements) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, replace_values(nested, replacements)} end)
  end

  defp replace_values(values, replacements) when is_list(values), do: Enum.map(values, &replace_values(&1, replacements))

  defp replace_values(value, replacements) when is_binary(value) do
    Enum.reduce(replacements, value, fn {placeholder, replacement}, acc ->
      String.replace(acc, placeholder, replacement)
    end)
  end

  defp replace_values(value, _replacements), do: value

  defp replace_path(_value, [], replacement), do: replacement

  defp replace_path(value, [index | rest], replacement) when is_list(value) and is_integer(index) do
    List.update_at(value, index, &replace_path(&1, rest, replacement))
  end

  defp replace_path(value, [key | rest], replacement) when is_map(value) do
    Map.update!(value, key, &replace_path(&1, rest, replacement))
  end

  defp provider_requests(provider) do
    provider
    |> Agent.get(& &1.requests)
    |> Enum.map(fn
      {:raw, "SymphonyLinearIntakeIssueById", _payload} -> :lookup
      {:raw, "SymphonyLinearIssuesById", _payload} -> :lookup_fallback
      {:raw, "SymphonyLinearIntakeIssueCreate", _payload} -> :create
      {:raw, "SymphonyLinearPoll", _payload} -> :poll
    end)
  end

  defp assert_direct_lookup!(provider, intake_case) do
    requests = Agent.get(provider, & &1.requests)
    lookup_payloads = for {:raw, "SymphonyLinearIntakeIssueById", payload} <- requests, do: payload
    assert lookup_payloads != []

    Enum.each(lookup_payloads, fn payload ->
      assert payload["operationName"] == "SymphonyLinearIntakeIssueById"
      assert payload["query"] =~ "issue(id: $id)"
      refute payload["query"] =~ "issues(filter:"
      assert payload["variables"][:id] == intake_case.linear_issue_id
    end)
  end

  defp assert_filter_lookup!(provider, intake_case) do
    requests = Agent.get(provider, & &1.requests)
    lookup_payloads = for {:raw, "SymphonyLinearIssuesById", payload} <- requests, do: payload
    assert lookup_payloads != []

    Enum.each(lookup_payloads, fn payload ->
      assert payload["operationName"] == "SymphonyLinearIssuesById"
      assert payload["query"] =~ "issues(filter: {id: {eq: $id}}"
      assert payload["variables"][:id] == intake_case.linear_issue_id
      assert payload["variables"][:first] == 1
    end)
  end

  defp create_inputs(provider) do
    Agent.get(provider, & &1.inputs)
  end

  defp assert_create_input!(input, intake_case) do
    assert input[:id] == intake_case.linear_issue_id
    assert input[:teamId] == @team_id
    assert input[:projectId] == @project_id
    assert input[:stateId] == @todo_id
    assert input[:labelIds] == [@label_id]
    assert String.starts_with?(input[:title], "[#{intake_case.jira_key}] ")
    assert String.length(input[:title]) <= 255
  end

  defp assert_confirmed!(intake_case, identifier, url) do
    stored = Repo.get!(IntakeCase, intake_case.id)
    assert stored.linear_issue_id == intake_case.linear_issue_id
    assert stored.linear_identifier == identifier
    assert stored.linear_url == url
    assert stored.linear_state_name == "Todo"
    assert %DateTime{} = stored.linear_confirmed_at
  end
end
