defmodule SymphonyElixir.Intake.Preview do
  @moduledoc """
  Dry run of a saved rule: reads the current Jira matches and reports them
  without any write, neither in Jira nor in the database.

  The sample holds at most 20 issues without descriptions. Warnings report
  issues already linked to a case, other active rules watching the same source
  and, for `include_existing`, how many existing issues activation imports.
  """

  import Ecto.Query

  alias SymphonyElixir.Intake.JiraAccess
  alias SymphonyElixir.Jira.{CloudClient, Issue}
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{AutomationRule, IntakeCase, IntegrationConnection}

  @sample_limit 20
  @max_issues 10_000
  @title_limit 200

  @spec run(AutomationRule.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%AutomationRule{} = rule, opts \\ []) do
    with %IntegrationConnection{} = connection <- Repo.get(IntegrationConnection, rule.jira_connection_id),
         {:ok, client_opts} <- JiraAccess.client_opts(connection, opts),
         {:ok, issues} <- search(rule, client_opts) do
      {:ok, build(rule, connection, issues)}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp search(rule, client_opts) do
    counter = :counters.new(1, [])

    page_fun = fn page ->
      :counters.add(counter, 1, length(page))
      if :counters.get(counter, 1) > @max_issues, do: {:error, %{kind: :scan_limit_exceeded}}, else: :ok
    end

    client_opts
    |> Keyword.put(:page_fun, page_fun)
    |> then(&search_source(rule, &1))
    |> case do
      {:ok, issues} -> {:ok, issues}
      {:error, %{kind: :scan_limit_exceeded}} -> {:error, :scan_limit_exceeded}
      {:error, reason} -> {:error, {:dependency, JiraAccess.error_code(reason)}}
    end
  end

  defp search_source(%AutomationRule{source_type: "board"} = rule, client_opts),
    do: CloudClient.search_board_issues(rule.source_id, rule.priority_ids, client_opts)

  defp search_source(%AutomationRule{} = rule, client_opts),
    do: CloudClient.search_filter_issues(rule.source_id, rule.priority_ids, client_opts)

  defp build(rule, connection, issues) do
    linked = linked_issue_ids(connection.id, Enum.map(issues, &to_string(&1.id)))
    site_url = Map.get(connection.settings || %{}, "site_url")
    match_count = length(issues)

    %{
      rule_id: rule.id,
      config_version: rule.config_version,
      sample: issues |> Enum.take(@sample_limit) |> Enum.map(&sample_item(&1, site_url, linked)),
      sample_limit: @sample_limit,
      match_count: match_count,
      truncated: match_count > @sample_limit,
      warnings: warnings(rule, match_count, map_size(linked))
    }
  end

  defp sample_item(%Issue{} = issue, site_url, linked) do
    %{
      jira_issue_id: to_string(issue.id),
      key: issue.key,
      title: short_title(issue.summary),
      priority_id: issue.priority_id,
      priority_name: issue.priority_name,
      status_name: issue.status_name,
      url: if(is_binary(site_url), do: Issue.browse_url(issue, site_url)),
      already_linked: Map.has_key?(linked, to_string(issue.id))
    }
  end

  # A plain map keyed by issue ID: `MapSet.new/0` and `MapSet.new/1` in two
  # clauses give Dialyzer a union that breaks the opaque `MapSet.t()`.
  defp linked_issue_ids(_connection_id, []), do: %{}

  defp linked_issue_ids(connection_id, issue_ids) do
    from(intake_case in IntakeCase,
      where: intake_case.jira_connection_id == ^connection_id and intake_case.jira_issue_id in ^issue_ids,
      select: intake_case.jira_issue_id
    )
    |> Repo.all()
    |> Map.new(&{&1, true})
  end

  defp warnings(rule, match_count, linked_count) do
    [
      linked_count > 0 && %{code: "already_linked", count: linked_count},
      source_conflict(rule),
      rule.initial_policy == "include_existing" && %{code: "include_existing_import", count: match_count - linked_count}
    ]
    |> Enum.filter(&is_map/1)
  end

  defp source_conflict(rule) do
    conflicts =
      Repo.all(
        from(other in AutomationRule,
          where:
            other.id != ^rule.id and other.jira_connection_id == ^rule.jira_connection_id and
              other.source_type == ^rule.source_type and other.source_id == ^rule.source_id and
              (other.enabled or other.activation_status == "activating"),
          select: %{rule_id: other.id, project_id: other.project_id}
        )
      )

    conflicts != [] && %{code: "source_conflict", rules: conflicts}
  end

  defp short_title(summary) when is_binary(summary) do
    normalized = summary |> String.replace(~r/[[:cntrl:]\s]+/u, " ") |> String.trim()

    if String.length(normalized) > @title_limit,
      do: String.slice(normalized, 0, @title_limit - 1) <> "…",
      else: normalized
  end

  defp short_title(_summary), do: ""
end
