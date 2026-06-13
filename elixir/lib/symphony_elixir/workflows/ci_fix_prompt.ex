defmodule SymphonyElixir.Workflows.CiFixPrompt do
  @moduledoc """
  Builds the Codex prompt for failed GitHub Actions repair work.
  """

  alias SymphonyElixir.WorkRun

  @spec build(WorkRun.t()) :: String.t()
  def build(%WorkRun{} = run) do
    workflow_run = payload_value(run.payload, :workflow_run, %{})
    log_excerpt = payload_value(run.payload, :log_excerpt, "No log excerpt captured.")

    """
    Fix the failed GitHub Actions run for #{run.forge_owner}/#{run.forge_repo} PR ##{run.forge_pr_number}.

    Branch policy:
    - Work only on branch #{run.forge_head_ref}.
    - Base branch is #{run.forge_base_ref}.
    - Do not merge the pull request.
    - Do not push directly to #{run.forge_base_ref}.

    Failing workflow:
    - Name: #{payload_value(workflow_run, :name, "unknown")}
    - Run ID: #{payload_value(workflow_run, :id, "unknown")}
    - URL: #{payload_value(workflow_run, :url, "unknown")}

    Log excerpt:
    #{log_excerpt}

    End state:
    - Push the minimal fix to the PR branch when permitted.
    - Leave a concise handoff summary.
    """
  end

  defp payload_value(%{} = payload, key, default) do
    Map.get(payload, key) || Map.get(payload, to_string(key)) || default
  end

  defp payload_value(_payload, _key, default), do: default
end
