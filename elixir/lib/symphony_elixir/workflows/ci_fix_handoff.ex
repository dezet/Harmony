defmodule SymphonyElixir.Workflows.CiFixHandoff do
  @moduledoc """
  Reports failed CI repair blockers to GitHub and linked Linear issues.
  """

  alias SymphonyElixir.{Github, RuntimePolicy, Tracker, WorkRun}

  @default_human_review_state "Human Review"

  @spec blocked(WorkRun.t()) :: :ok | {:error, term()}
  def blocked(%WorkRun{} = run), do: blocked(run, [])

  @spec blocked(WorkRun.t(), keyword()) :: :ok | {:error, term()}
  def blocked(%WorkRun{} = run, opts) when is_list(opts) do
    body = blocked_body(blocker_reason(run))
    github_comment = Keyword.get(opts, :github_comment, &Github.Client.create_issue_comment/5)
    linear_comment = Keyword.get(opts, :linear_comment, &Tracker.create_comment/2)
    linear_state = Keyword.get(opts, :linear_state, &Tracker.update_issue_state/2)
    human_review_state = Keyword.get(opts, :human_review_state, @default_human_review_state)

    with :ok <- github_comment.(run.github_owner, run.github_repo, run.github_pr_number, body, []),
         :ok <- maybe_linear_comment(run, body, linear_comment) do
      RuntimePolicy.Handoff.move_to_human_review(
        %{linear_issue_id: run.linear_issue_id},
        human_review_state,
        tracker_update: linear_state
      )
    end
  end

  defp maybe_linear_comment(%WorkRun{linear_issue_id: issue_id}, body, linear_comment)
       when is_binary(issue_id) and issue_id != "" do
    linear_comment.(issue_id, body)
  end

  defp maybe_linear_comment(_run, _body, _linear_comment), do: :ok

  defp blocked_body(reason) do
    """
    Harmony could not complete the failed CI repair automatically.

    Reason:
    #{reason}

    The PR remains unmerged for human review.
    """
  end

  defp blocker_reason(%WorkRun{payload: payload}) when is_map(payload) do
    Map.get(payload, :blocker_reason) || Map.get(payload, "blocker_reason") || "unknown"
  end
end
