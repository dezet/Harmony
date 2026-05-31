defmodule SymphonyElixir.Workflows.CiFixPrompt do
  @moduledoc """
  Builds the Codex prompt for failed GitHub Actions repair work.
  """

  alias SymphonyElixir.WorkRun

  @spec build(WorkRun.t()) :: String.t()
  def build(%WorkRun{} = run) do
    workflow_run = Map.get(run.payload, :workflow_run) || Map.get(run.payload, "workflow_run") || %{}
    log_excerpt = Map.get(run.payload, :log_excerpt) || Map.get(run.payload, "log_excerpt") || "No log excerpt captured."

    """
    Fix the failed GitHub Actions run for #{run.github_owner}/#{run.github_repo} PR ##{run.github_pr_number}.

    Branch policy:
    - Work only on branch #{run.github_head_ref}.
    - Base branch is #{run.github_base_ref}.
    - Do not merge the pull request.
    - Do not push directly to #{run.github_base_ref}.

    Failing workflow:
    - Name: #{Map.get(workflow_run, :name) || Map.get(workflow_run, "name") || "unknown"}
    - Run ID: #{Map.get(workflow_run, :id) || Map.get(workflow_run, "id") || "unknown"}
    - URL: #{Map.get(workflow_run, :url) || Map.get(workflow_run, "url") || "unknown"}

    Log excerpt:
    #{log_excerpt}

    End state:
    - Push the minimal fix to the PR branch when permitted.
    - Leave a concise handoff summary.
    """
  end
end
