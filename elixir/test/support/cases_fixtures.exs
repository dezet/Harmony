defmodule SymphonyElixir.CasesFixtures do
  @moduledoc """
  Synthetic intake cases, deliveries, events and legacy work runs for the
  `/cases` projection tests. Every identifier, URL and recipient is fake.
  """

  alias SymphonyElixir.Repo

  alias SymphonyElixir.Storage.{
    AutomationRule,
    IntakeAnalysis,
    IntakeCase,
    IntakeEvent,
    IntegrationConnection,
    IntegrationDelivery,
    Project,
    WorkEvent,
    WorkRun
  }

  @base_time ~U[2026-09-22 10:00:00.000000Z]

  def base_time, do: @base_time

  def at(minutes_before), do: DateTime.add(@base_time, -minutes_before * 60, :second)

  def project!(attrs \\ %{}) do
    %Project{}
    |> Project.changeset(
      Map.merge(
        %{
          slug: "cases-#{System.unique_integer([:positive])}",
          linear_project_slug: "cases",
          linear_team_key: "OPS",
          forge_owner: "example",
          forge_repo: "synthetic",
          forge_base_branch: "main",
          config_version: 1,
          config: %{}
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  def jira_connection! do
    %IntegrationConnection{}
    |> IntegrationConnection.changeset(%{
      kind: "jira_cloud",
      name: "Jira #{System.unique_integer([:positive])}",
      settings: %{
        "site_url" => "https://cases-#{System.unique_integer([:positive])}.atlassian.net",
        "auth_mode" => "classic",
        "account_email" => "ops@example.test"
      },
      secret: "synthetic-jira-token",
      enabled: true
    })
    |> Repo.insert!()
  end

  def rule!(project, jira) do
    %AutomationRule{}
    |> AutomationRule.changeset(%{
      name: "Pilne zgłoszenia",
      project_id: project.id,
      jira_connection_id: jira.id,
      source_type: "board",
      source_id: "#{System.unique_integer([:positive])}",
      priority_ids: ["1", "2"],
      interval_seconds: 300,
      initial_policy: "new_matches_only",
      linear_team_id: "33333333-3333-4333-8333-333333333333",
      linear_project_id: "44444444-4444-4444-8444-444444444444",
      linear_todo_state_id: "66666666-6666-4666-8666-666666666666",
      linear_hold_label_id: "77777777-7777-4777-8777-777777777777",
      email_connection_id: nil,
      sms_connection_id: nil,
      email_recipients: [],
      sms_recipients: []
    })
    |> Repo.insert!()
  end

  @doc "A project with a Jira connection and a rule, ready for cases."
  def scope!(project_attrs \\ %{}) do
    project = project!(project_attrs)
    jira = jira_connection!()
    %{project: project, jira: jira, rule: rule!(project, jira)}
  end

  def intake_case!(%{project: project, jira: jira, rule: rule}, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    key = Map.get(attrs, :jira_key, "OPS-#{n}")
    detected_at = Map.get(attrs, :detected_at, @base_time)

    defaults = %{
      project_id: project.id,
      rule_id: rule.id,
      jira_connection_id: jira.id,
      jira_issue_id: "issue-#{n}",
      jira_key: key,
      jira_url: "#{jira.settings["site_url"]}/browse/#{key}",
      title: "Synthetic case #{n}",
      description_text: "Synthetic description",
      priority_id: "1",
      priority_name: "Highest",
      jira_updated_at: detected_at,
      detected_at: detected_at,
      rule_snapshot: %{
        "name" => rule.name,
        "source_type" => "board",
        "source_id" => rule.source_id,
        "priority_ids" => ["1", "2"],
        "initial_policy" => "new_matches_only",
        "email_recipients" => ["oncall@example.test"],
        "sms_recipients" => ["+19995550123"],
        "qualified_at" => DateTime.to_iso8601(detected_at)
      },
      linear_issue_id: Ecto.UUID.generate(),
      linear_identifier: "LIN-#{n}",
      linear_url: "https://linear.example/issue/LIN-#{n}",
      linear_state_name: "Todo",
      linear_confirmed_at: detected_at,
      analysis_version: 1,
      analysis_status: "queued",
      lock_version: 1
    }

    %IntakeCase{}
    |> IntakeCase.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  @doc "A ready case with a succeeded analysis and, by default, a published comment."
  def ready_case!(scope, attrs \\ %{}, opts \\ []) do
    intake_case = intake_case!(scope, Map.merge(%{analysis_status: "ready"}, attrs))
    analysis!(intake_case, %{status: "succeeded"})
    if Keyword.get(opts, :published?, true), do: delivery!(intake_case, "jira_comment", "succeeded")
    intake_case
  end

  def analysis!(intake_case, attrs \\ %{}) do
    version = Map.get(attrs, :version, intake_case.analysis_version)
    status = Map.get(attrs, :status, "succeeded")

    result =
      if status in ["succeeded", "needs_input"] do
        %{
          "summary" => "Synthetic summary",
          "facts" => [%{"text" => "Synthetic fact", "source" => "jira:#{intake_case.jira_key}"}],
          "hypotheses" => [%{"text" => "Synthetic hypothesis", "confidence" => "medium", "evidence" => ["jira:#{intake_case.jira_key}"]}],
          "missing_data" => [],
          "next_steps" => ["Synthetic step"],
          "needs_input" => status == "needs_input",
          "context_scope" => "issue_only"
        }
      end

    %IntakeAnalysis{}
    |> IntakeAnalysis.changeset(
      Map.merge(
        %{
          case_id: intake_case.id,
          version: version,
          status: status,
          input_snapshot: %{
            "case_ref" => "jira_#{intake_case.id}",
            "jira_key" => intake_case.jira_key,
            "context_scope" => "issue_only",
            "description_text" => intake_case.description_text,
            "rule_snapshot" => intake_case.rule_snapshot
          },
          result: result,
          model: "synthetic-analysis-model",
          effort: "medium",
          started_at: at(-1),
          completed_at: if(status in ["succeeded", "needs_input", "failed"], do: at(-2)),
          token_usage: %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15},
          error_code: if(status == "failed", do: "synthetic_failure")
        },
        Map.drop(attrs, [:version, :status])
      )
    )
    |> Repo.insert!()
  end

  def delivery!(intake_case, operation, status, attrs \\ %{}) do
    version = Map.get(attrs, :version, intake_case.analysis_version)
    succeeded? = status == "succeeded"

    %IntegrationDelivery{}
    |> IntegrationDelivery.changeset(%{
      case_id: intake_case.id,
      operation: operation,
      dedupe_key: delivery_key(intake_case, operation, version),
      payload: delivery_payload(operation, version, attrs),
      status: status,
      attempts: 1,
      next_attempt_at: @base_time,
      provider_id: if(succeeded?, do: "provider-#{System.unique_integer([:positive])}"),
      first_attempt_at: @base_time,
      sent_at: if(succeeded?, do: @base_time),
      last_error_code: if(status in ["failed", "unknown", "retry_wait"], do: "synthetic_failure")
    })
    |> Repo.insert!()
  end

  defp delivery_key(intake_case, "analysis", version), do: "case:#{intake_case.id}:analysis:#{version}"
  defp delivery_key(intake_case, "jira_comment", version), do: "case:#{intake_case.id}:jira-comment:#{version}"
  defp delivery_key(intake_case, "linear_create", _version), do: "case:#{intake_case.id}:linear:v1"
  defp delivery_key(intake_case, channel, _version), do: "case:#{intake_case.id}:#{channel}:#{Ecto.UUID.generate()}:detected:v1"

  defp delivery_payload(channel, _version, attrs) when channel in ["email", "sms"],
    do: %{"recipient" => Map.get(attrs, :recipient, "oncall@example.test")}

  defp delivery_payload(_operation, version, _attrs), do: %{"version" => version}

  def event!(intake_case, type, payload, occurred_at) do
    %IntakeEvent{}
    |> IntakeEvent.changeset(%{
      case_id: intake_case.id,
      rule_id: intake_case.rule_id,
      type: type,
      payload: payload,
      actor: "system",
      occurred_at: occurred_at
    })
    |> Repo.insert!()
  end

  def work_run!(project, attrs \\ %{}) do
    inserted_at = Map.get(attrs, :inserted_at, @base_time)

    %WorkRun{}
    |> WorkRun.changeset(
      Map.merge(
        %{
          project_id: project.id,
          type: "implementation",
          status: "queued",
          agent_backend: "codex",
          payload: %{}
        },
        Map.delete(attrs, :inserted_at)
      )
    )
    |> Ecto.Changeset.put_change(:inserted_at, inserted_at)
    |> Ecto.Changeset.put_change(:updated_at, inserted_at)
    |> Repo.insert!()
  end

  def work_event!(work_run, type, payload, inserted_at) do
    %WorkEvent{}
    |> WorkEvent.changeset(%{project_id: work_run.project_id, work_run_id: work_run.id, type: type, payload: payload})
    |> Ecto.Changeset.put_change(:inserted_at, inserted_at)
    |> Repo.insert!()
  end
end
