defmodule SymphonyElixir.Workflows.CiFixHandoff do
  @moduledoc """
  Reports failed CI repair blockers to GitHub and linked Linear issues.
  """

  alias SymphonyElixir.{Github, RuntimePolicy, Storage, Tracker, WorkRun}

  @default_human_review_state "Human Review"

  @spec blocked(WorkRun.t()) :: :ok | {:error, term()}
  def blocked(%WorkRun{} = run), do: blocked(run, [])

  @spec blocked(WorkRun.t(), keyword()) :: :ok | {:error, term()}
  def blocked(%WorkRun{} = run, opts) when is_list(opts) do
    body = blocked_body(blocker_reason(run))
    github_comment = Keyword.get(opts, :github_comment, &Github.Client.create_issue_comment/5)
    linear_comment = Keyword.get(opts, :linear_comment, &Tracker.create_comment/2)
    linear_state = Keyword.get(opts, :linear_state, &Tracker.update_issue_state/2)
    append_event = Keyword.get(opts, :append_event, &Storage.append_event/1)
    human_review_state = Keyword.get(opts, :human_review_state, @default_human_review_state)

    with :ok <- github_comment.(run.github_owner, run.github_repo, run.github_pr_number, body, []),
         :ok <- append_work_event(run, append_event, "github_comment_created", %{"github_pr_number" => run.github_pr_number}),
         :ok <- maybe_linear_comment(run, body, linear_comment),
         :ok <- maybe_append_linear_comment_event(run, append_event) do
      RuntimePolicy.Handoff.move_to_human_review(
        %{
          id: run.id,
          project_id: payload_value(run.payload, :project_id),
          linear_issue_id: run.linear_issue_id
        },
        human_review_state,
        tracker_update: linear_state,
        append_event: append_event
      )
    end
  end

  defp maybe_linear_comment(%WorkRun{linear_issue_id: issue_id}, body, linear_comment)
       when is_binary(issue_id) and issue_id != "" do
    linear_comment.(issue_id, body)
  end

  defp maybe_linear_comment(_run, _body, _linear_comment), do: :ok

  defp maybe_append_linear_comment_event(%WorkRun{linear_issue_id: issue_id} = run, append_event)
       when is_binary(issue_id) and issue_id != "" do
    append_work_event(run, append_event, "linear_comment_created", %{"linear_issue_id" => issue_id})
  end

  defp maybe_append_linear_comment_event(_run, _append_event), do: :ok

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

  defp append_work_event(%WorkRun{id: id, payload: payload} = run, append_event, type, payload_attrs)
       when is_binary(id) do
    case payload_value(payload, :project_id) do
      project_id when is_binary(project_id) ->
        %{
          project_id: project_id,
          work_run_id: run.id,
          type: type,
          payload: payload_attrs
        }
        |> append_event.()
        |> normalize_event_result()

      _missing_project ->
        :ok
    end
  end

  defp append_work_event(_run, _append_event, _type, _payload_attrs), do: :ok

  defp payload_value(payload, key) when is_map(payload), do: Map.get(payload, key) || Map.get(payload, to_string(key))

  defp normalize_event_result(:ok), do: :ok
  defp normalize_event_result({:ok, _event}), do: :ok
  defp normalize_event_result({:error, reason}), do: {:error, reason}
end
