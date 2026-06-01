defmodule SymphonyElixir.Workflows.ReviewPrompt do
  @moduledoc """
  Builds the Codex prompt for requested GitHub PR review work.
  """

  alias SymphonyElixir.WorkRun

  @default_template """
  Review correctness, tests, maintainability, security, and operational risk.
  Lead with findings ordered by severity. Include concrete file and line references when you can determine them.
  """

  @spec build(WorkRun.t()) :: String.t()
  def build(%WorkRun{} = run) do
    """
    Perform a comprehensive code review for #{run.github_owner}/#{run.github_repo} PR ##{run.github_pr_number}.

    Review target:
    - Head SHA: #{run.github_head_sha || "unknown"}
    - Head branch: #{run.github_head_ref || "unknown"}
    - Base branch: #{run.github_base_ref || "unknown"}
    - Trigger comment ID: #{payload_value(run.payload, :trigger_comment_id) || "unknown"}

    Review template:
    #{review_template(run)}

    Output contract:
    - Produce one aggregate GitHub pull request review body.
    - Do not write inline diff comments in this MVP workflow.
    - Lead with findings, ordered by severity.
    - For each finding, include concrete file and line references when you can determine them.
    - Include missing test coverage when it creates meaningful risk.
    - Keep summaries brief and secondary to findings.
    - If there are no findings, say that clearly and mention residual risk or test gaps.
    - Do not request changes automatically.
    - Do not approve the pull request.
    - Do not merge the pull request.
    """
  end

  defp review_template(%WorkRun{payload: payload}) do
    case payload_value(payload, :template) do
      template when is_binary(template) and template != "" -> template
      _other -> @default_template
    end
  end

  defp payload_value(%{} = payload, key), do: Map.get(payload, key) || Map.get(payload, to_string(key))
  defp payload_value(_payload, _key), do: nil
end
