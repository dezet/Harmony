defmodule SymphonyElixir.WorkSources.LinearIssueSource do
  @moduledoc """
  Converts tracker Linear issues into implementation work runs.
  """

  @behaviour SymphonyElixir.WorkSource

  alias SymphonyElixir.Intake.ExecutionGate
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.{Tracker, WorkRun}

  @impl true
  @spec fetch_candidates(keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(opts \\ []) do
    scope_opts = linear_scope_options(opts)
    issue_fetcher = Keyword.get(opts, :issue_fetcher) || default_issue_fetcher(scope_opts)

    with {:ok, issues} <- invoke_issue_fetcher(issue_fetcher, scope_opts) do
      issues = filter_to_project(issues, scope_opts)
      gate = Keyword.get(opts, :execution_gate_fun, &ExecutionGate.authorize_implementation/2)
      project_id = Keyword.get(opts, :project_id)

      Enum.reduce_while(issues, {:ok, []}, fn issue, acc ->
        collect_issue(issue, acc, gate, project_id, opts)
      end)
      |> case do
        {:ok, runs} -> {:ok, Enum.reverse(runs)}
        error -> error
      end
    end
  end

  defp collect_issue(issue, {:ok, runs}, gate, project_id, opts) do
    case gate.(issue, project_id) do
      :ok ->
        {:cont, {:ok, [build_work_run(issue, project_id, opts) | runs]}}

      {:error, reason}
      when reason in [
             :analysis_only,
             :stale_approval,
             :unlinked_managed_issue,
             :project_mismatch,
             :invalid_issue,
             :incomplete_case
           ] ->
        {:cont, {:ok, runs}}

      {:error, reason} ->
        {:halt, {:error, {:execution_gate, reason}}}

      other ->
        {:halt, {:error, {:invalid_execution_gate_result, other}}}
    end
  end

  defp build_work_run(issue, project_id, opts) do
    WorkRun.from_linear_issue(issue,
      project_id: project_id,
      project_slug: Keyword.get(opts, :project_slug),
      base_branch: Keyword.get(opts, :base_branch),
      config_version: Keyword.get(opts, :config_version),
      required_evidence: Keyword.get(opts, :required_evidence, [])
    )
  end

  defp linear_scope_options(opts) do
    opts
    |> Keyword.take([:project_slug, :linear_project_slug, :token, :request_fun, :timeout_ms])
    |> then(fn scope_opts ->
      case Keyword.get(scope_opts, :linear_project_slug) || Keyword.get(scope_opts, :project_slug) do
        project_slug when is_binary(project_slug) -> Keyword.put_new(scope_opts, :linear_project_slug, project_slug)
        _ -> scope_opts
      end
    end)
  end

  defp default_issue_fetcher(scope_opts) do
    if is_binary(Keyword.get(scope_opts, :linear_project_slug)) do
      fn opts -> Client.fetch_candidate_issues(opts) end
    else
      &Tracker.fetch_candidate_issues/0
    end
  end

  defp invoke_issue_fetcher(issue_fetcher, scope_opts) when is_function(issue_fetcher, 1),
    do: issue_fetcher.(scope_opts)

  defp invoke_issue_fetcher(issue_fetcher, _scope_opts) when is_function(issue_fetcher, 0),
    do: issue_fetcher.()

  defp invoke_issue_fetcher(_issue_fetcher, _scope_opts), do: {:error, :invalid_issue_fetcher}

  defp filter_to_project(issues, scope_opts) when is_list(issues) do
    case Keyword.get(scope_opts, :linear_project_slug) do
      project_slug when is_binary(project_slug) ->
        Enum.filter(issues, &match?(%{project_slug: ^project_slug}, &1))

      _ ->
        issues
    end
  end
end
