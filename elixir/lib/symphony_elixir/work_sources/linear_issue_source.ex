defmodule SymphonyElixir.WorkSources.LinearIssueSource do
  @moduledoc """
  Converts tracker Linear issues into implementation work runs.
  """

  @behaviour SymphonyElixir.WorkSource

  alias SymphonyElixir.{Tracker, WorkRun}
  alias SymphonyElixir.Intake.ExecutionGate

  @impl true
  @spec fetch_candidates(keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(opts \\ []) do
    issue_fetcher = Keyword.get(opts, :issue_fetcher, &Tracker.fetch_candidate_issues/0)

    with {:ok, issues} <- issue_fetcher.() do
      gate = Keyword.get(opts, :execution_gate_fun, &ExecutionGate.authorize_implementation/2)
      project_id = Keyword.get(opts, :project_id)

      Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, runs} ->
        case gate.(issue, project_id) do
          :ok ->
            run =
              WorkRun.from_linear_issue(issue,
                project_id: project_id,
                project_slug: Keyword.get(opts, :project_slug),
                base_branch: Keyword.get(opts, :base_branch),
                config_version: Keyword.get(opts, :config_version),
                required_evidence: Keyword.get(opts, :required_evidence, [])
              )

            {:cont, {:ok, [run | runs]}}

          {:error, reason} when reason in [:analysis_only, :stale_approval, :unlinked_managed_issue, :project_mismatch, :invalid_issue, :incomplete_case] ->
            {:cont, {:ok, runs}}

          {:error, reason} ->
            {:halt, {:error, {:execution_gate, reason}}}

          other ->
            {:halt, {:error, {:invalid_execution_gate_result, other}}}
        end
      end)
      |> case do
        {:ok, runs} -> {:ok, Enum.reverse(runs)}
        error -> error
      end
    end
  end
end
