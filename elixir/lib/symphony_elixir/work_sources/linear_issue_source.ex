defmodule SymphonyElixir.WorkSources.LinearIssueSource do
  @moduledoc """
  Converts tracker Linear issues into implementation work runs.
  """

  @behaviour SymphonyElixir.WorkSource

  alias SymphonyElixir.{Tracker, WorkRun}

  @impl true
  def fetch_candidates(opts \\ []) do
    issue_fetcher = Keyword.get(opts, :issue_fetcher, &Tracker.fetch_candidate_issues/0)

    with {:ok, issues} <- issue_fetcher.() do
      runs =
        Enum.map(issues, fn issue ->
          WorkRun.from_linear_issue(issue,
            project_id: Keyword.get(opts, :project_id),
            project_slug: Keyword.get(opts, :project_slug),
            base_branch: Keyword.get(opts, :base_branch),
            config_version: Keyword.get(opts, :config_version),
            required_evidence: Keyword.get(opts, :required_evidence, [])
          )
        end)

      {:ok, runs}
    end
  end
end
