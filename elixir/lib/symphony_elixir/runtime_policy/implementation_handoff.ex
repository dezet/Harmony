defmodule SymphonyElixir.RuntimePolicy.ImplementationHandoff do
  @moduledoc """
  Runtime handoff for completed Linear implementation work.
  """

  alias SymphonyElixir.{RuntimePolicy, Storage, Tracker, WorkRun}

  @default_human_review_state "Human Review"

  @spec publish(WorkRun.t(), keyword()) :: :ok | {:error, term()}
  def publish(%WorkRun{} = run, opts \\ []) when is_list(opts) do
    project_id = payload_value(run.payload, :project_id)
    get_project = Keyword.get(opts, :get_project, &Storage.get_project!/1)
    find_pr_link = Keyword.get(opts, :find_pull_request_link, &Storage.find_pull_request_link_for_linear/3)

    with {:ok, project_id} <- require_project_id(project_id),
         project <- get_project.(project_id),
         pr_link <- find_pr_link.(project_id, run.linear_issue_id, run.linear_identifier),
         {:ok, pr_link} <- require_pr_link(pr_link, run, opts),
         :ok <- validate_pr_link(pr_link, project, run, opts) do
      move_to_human_review(run, project, pr_link, opts)
    end
  end

  defp require_project_id(project_id) when is_binary(project_id) and project_id != "", do: {:ok, project_id}
  defp require_project_id(_project_id), do: {:error, :missing_project_id}

  defp require_pr_link(nil, %WorkRun{} = run, opts) do
    reason = :missing_pull_request_link
    body = missing_pr_body(run)

    with :ok <- maybe_linear_comment(run, body, opts),
         :ok <- record_blocker(run, Atom.to_string(reason), %{}, opts) do
      {:error, reason}
    end
  end

  defp require_pr_link(pr_link, _run, _opts), do: {:ok, pr_link}

  defp validate_pr_link(pr_link, project, %WorkRun{} = run, opts) do
    cond do
      base_ref(pr_link) != expected_base_ref(project, run) ->
        block_invalid_pr(run, :base_branch_mismatch, pr_link, opts)

      head_ref(pr_link) in [nil, ""] ->
        block_invalid_pr(run, :missing_head_branch, pr_link, opts)

      head_ref(pr_link) == base_ref(pr_link) ->
        block_invalid_pr(run, :head_matches_base_branch, pr_link, opts)

      true ->
        :ok
    end
  end

  defp block_invalid_pr(%WorkRun{} = run, reason, pr_link, opts) do
    blocker_reason = "invalid_pull_request_link:#{reason}"

    with :ok <- record_blocker(run, blocker_reason, pr_link_metadata(pr_link), opts) do
      {:error, {:invalid_pull_request_link, reason}}
    end
  end

  defp move_to_human_review(%WorkRun{} = run, project, pr_link, opts) do
    handoff = Keyword.get(opts, :handoff, &RuntimePolicy.Handoff.move_to_human_review/3)
    tracker_update = Keyword.get(opts, :tracker_update, &Tracker.update_issue_state/2)
    append_event = Keyword.get(opts, :append_event, &Storage.append_event/1)
    artifacts = Keyword.get(opts, :artifacts, [])

    work = %{
      id: run.id,
      project_id: payload_value(run.payload, :project_id),
      linear_issue_id: run.linear_issue_id,
      required_evidence: run.required_evidence,
      pull_request: pr_link_metadata(pr_link)
    }

    handoff.(work, human_review_state(project),
      tracker_update: tracker_update,
      append_event: append_event,
      artifacts: artifacts
    )
  end

  defp maybe_linear_comment(%WorkRun{linear_issue_id: issue_id}, body, opts)
       when is_binary(issue_id) and issue_id != "" do
    linear_comment = Keyword.get(opts, :linear_comment, &Tracker.create_comment/2)

    linear_comment.(issue_id, body)
  end

  defp maybe_linear_comment(_run, _body, _opts), do: :ok

  defp record_blocker(%WorkRun{} = run, reason, metadata, opts) do
    record = Keyword.get(opts, :record_blocker, &Storage.upsert_open_blocker/1)

    case payload_value(run.payload, :project_id) do
      project_id when is_binary(project_id) ->
        %{
          project_id: project_id,
          work_run_id: run.id,
          target_type: "linear_issue",
          target_id: run.linear_issue_id || run.linear_identifier || run.dedupe_key || "unknown",
          reason: reason,
          metadata:
            Map.merge(metadata, %{
              "linear_issue_id" => run.linear_issue_id,
              "linear_identifier" => run.linear_identifier
            })
        }
        |> record.()
        |> normalize_result()

      _missing_project ->
        :ok
    end
  end

  defp missing_pr_body(%WorkRun{} = run) do
    """
    Harmony completed the implementation run but could not find a linked pull request for #{run.linear_identifier || run.linear_issue_id}.

    The issue remains blocked until a PR is linked and reviewed.
    """
  end

  defp human_review_state(project) do
    project_value(project, :linear_human_review_state) || @default_human_review_state
  end

  defp expected_base_ref(project, %WorkRun{} = run) do
    run.github_base_ref || project_value(project, :github_base_branch)
  end

  defp pr_link_metadata(pr_link) do
    %{
      "github_pr_number" => project_value(pr_link, :github_pr_number),
      "github_head_ref" => head_ref(pr_link),
      "github_base_ref" => base_ref(pr_link)
    }
  end

  defp head_ref(pr_link), do: project_value(pr_link, :github_head_ref)
  defp base_ref(pr_link), do: project_value(pr_link, :github_base_ref)

  defp payload_value(%{} = payload, key), do: Map.get(payload, key) || Map.get(payload, to_string(key))
  defp payload_value(_payload, _key), do: nil

  defp project_value(%{} = map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp project_value(struct, key) when is_struct(struct), do: struct |> Map.from_struct() |> project_value(key)
  defp project_value(_project, _key), do: nil

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, _record}), do: :ok
  defp normalize_result({:error, reason}), do: {:error, reason}
end
