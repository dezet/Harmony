defmodule SymphonyElixir.Intake.ActivationCheck do
  @moduledoc """
  Activation requirements of a rule (spec §7.1), verified with reads only:

  * Jira: an enabled connection with credentials, its identity, the rule
    source (board configuration or saved filter) and every priority ID;
  * Linear: the team, the project in that team, the state named exactly
    `Todo` (the stored ID must be that state) and the hold label;
  * the analysis profile from the runtime configuration and the fixed
    analysis policy, without starting an analysis;
  * every selected notification channel: an enabled connection of the right
    kind with a secret, recipients and a valid `intake.public_url`. Both
    channels may be off.

  Unmet requirements are collected and returned with the code of the first
  one. An unavailable dependency stops the check with its error code.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Intake
  alias SymphonyElixir.Intake.{AnalysisPolicy, JiraAccess, LinearOptions}
  alias SymphonyElixir.Jira.CloudClient
  alias SymphonyElixir.Notifications.Templates
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{AutomationRule, IntegrationConnection, Project}

  @type failure :: {String.t(), String.t()}
  @type error :: {:activation_blocked, String.t(), %{String.t() => [String.t()]}} | {:dependency, String.t()}

  @doc """
  Options: `:jira_opts` and `:linear_opts` (injected request functions) and
  `:analysis_profile_fun` (defaults to `Intake.analysis_profile/0`).
  """
  @spec run(AutomationRule.t(), keyword()) :: :ok | {:error, error()}
  def run(%AutomationRule{} = rule, opts \\ []) do
    with {:ok, jira_failures} <- jira(rule, Keyword.get(opts, :jira_opts, [])),
         {:ok, linear_failures} <- linear(rule, Keyword.get(opts, :linear_opts, [])) do
      case jira_failures ++ linear_failures ++ analysis(opts) ++ channels(rule) do
        [] -> :ok
        [{code, _field} | _rest] = failures -> {:error, {:activation_blocked, code, fields(failures)}}
      end
    end
  end

  defp jira(rule, opts) do
    with %IntegrationConnection{enabled: true} = connection <- Repo.get(IntegrationConnection, rule.jira_connection_id),
         {:ok, client_opts} <- JiraAccess.client_opts(connection, opts),
         :ok <- jira_identity(connection, opts) do
      jira_source_and_priorities(rule, client_opts)
    else
      {:error, {:dependency, _code}} = error -> error
      {:error, :jira_invalid_configuration} -> {:ok, [{"jira_invalid_configuration", "jira_connection_id"}]}
      _unavailable -> {:ok, [{"jira_connection_unavailable", "jira_connection_id"}]}
    end
  end

  defp jira_identity(connection, opts) do
    case JiraAccess.check(connection, opts) do
      :ok -> :ok
      {:error, "jira_invalid_configuration"} -> {:error, :jira_invalid_configuration}
      {:error, "jira_credentials_missing"} -> {:error, :credentials_missing}
      {:error, code} -> {:error, {:dependency, code}}
    end
  end

  defp jira_source_and_priorities(rule, client_opts) do
    with {:ok, source_failures} <- jira_source(rule, client_opts),
         {:ok, priority_failures} <- jira_priorities(rule, client_opts) do
      {:ok, source_failures ++ priority_failures}
    end
  end

  defp jira_source(%AutomationRule{source_type: "board"} = rule, client_opts) do
    rule.source_id |> CloudClient.board_filter_id(client_opts) |> source_result()
  end

  defp jira_source(%AutomationRule{} = rule, client_opts) do
    rule.source_id |> CloudClient.filter_exists(client_opts) |> source_result()
  end

  defp source_result(:ok), do: {:ok, []}
  defp source_result({:ok, _filter_id}), do: {:ok, []}

  defp source_result({:error, %{kind: kind} = reason}) when kind in [:http_status, :invalid_request] do
    if kind == :invalid_request or reason.status == 404,
      do: {:ok, [{"jira_source_not_found", "source_id"}]},
      else: {:error, {:dependency, JiraAccess.error_code(reason)}}
  end

  defp source_result({:error, reason}), do: {:error, {:dependency, JiraAccess.error_code(reason)}}

  defp jira_priorities(rule, client_opts) do
    case CloudClient.list_priorities(client_opts) do
      {:ok, priorities} ->
        known = Enum.flat_map(priorities, &priority_id/1)
        if Enum.all?(rule.priority_ids, &(&1 in known)), do: {:ok, []}, else: {:ok, [{"jira_priority_unknown", "priority_ids"}]}

      {:error, reason} ->
        {:error, {:dependency, JiraAccess.error_code(reason)}}
    end
  end

  defp priority_id(%{"id" => id}) when is_binary(id) or is_integer(id), do: [to_string(id)]
  defp priority_id(_priority), do: []

  defp linear(rule, opts) do
    with %Project{} = project <- Repo.get(Project, rule.project_id),
         {:ok, options} <- LinearOptions.list(project, opts) do
      {:ok, linear_failures(rule, options)}
    else
      nil -> {:ok, [{"project_missing", "project_id"}]}
      {:error, _reason} = error -> error
    end
  end

  defp linear_failures(rule, options) do
    case Enum.find(options.teams, &(&1.id == rule.linear_team_id)) do
      nil ->
        [{"linear_team_missing", "linear_team_id"}]

      team ->
        [
          linear_project(rule, team, options.projects),
          target_state(team.todo_state_id, rule.linear_todo_state_id, "linear_todo_state", "linear_todo_state_id"),
          target_state(team.hold_label_id, rule.linear_hold_label_id, "linear_hold_label", "linear_hold_label_id")
        ]
        |> Enum.reject(&is_nil/1)
    end
  end

  defp linear_project(rule, team, projects) do
    if Enum.any?(projects, &(&1.id == rule.linear_project_id and team.id in &1.team_ids)),
      do: nil,
      else: {"linear_project_missing", "linear_project_id"}
  end

  defp target_state(nil, _stored_id, prefix, field), do: {prefix <> "_missing", field}
  defp target_state(id, id, _prefix, _field), do: nil
  defp target_state(_id, _stored_id, prefix, field), do: {prefix <> "_mismatch", field}

  # There is no side-effect-free way to start Codex, so the check covers the
  # configured profile and the fixed analysis policy only.
  defp analysis(opts) do
    profile_fun = Keyword.get(opts, :analysis_profile_fun, &Intake.analysis_profile/0)

    with {:ok, %{model: model, effort: effort}} <- profile_fun.(),
         {:ok, _policy} <- AnalysisPolicy.build(%{model: model, effort: effort}) do
      []
    else
      _unavailable -> [{"analysis_profile_unavailable", "analysis_profile"}]
    end
  end

  defp channels(rule) do
    channel_failures =
      channel(rule.email_connection_id, rule.email_recipients, "smtp", "email") ++
        channel(rule.sms_connection_id, rule.sms_recipients, "smsapi", "sms")

    if is_nil(rule.email_connection_id) and is_nil(rule.sms_connection_id),
      do: channel_failures,
      else: channel_failures ++ public_url()
  end

  defp channel(nil, _recipients, _kind, _prefix), do: []

  defp channel(connection_id, recipients, kind, prefix) do
    connection_failures =
      case Repo.get(IntegrationConnection, connection_id) do
        %IntegrationConnection{kind: ^kind, enabled: true, secret: secret} when is_binary(secret) and secret != "" -> []
        _unavailable -> [{prefix <> "_connection_unavailable", prefix <> "_connection_id"}]
      end

    recipient_failures = if recipients in [nil, []], do: [{prefix <> "_recipients_missing", prefix <> "_recipients"}], else: []
    connection_failures ++ recipient_failures
  end

  defp public_url do
    case Config.intake_settings().public_url do
      url when is_binary(url) ->
        case Templates.case_url(url, Ecto.UUID.generate()) do
          {:ok, _case_url} -> []
          {:error, :invalid_link} -> [{"intake_public_url_invalid", "public_url"}]
        end

      _missing ->
        [{"intake_public_url_invalid", "public_url"}]
    end
  end

  defp fields(failures) do
    Enum.reduce(failures, %{}, fn {code, field}, acc -> Map.update(acc, field, [code], &(&1 ++ [code])) end)
  end
end
