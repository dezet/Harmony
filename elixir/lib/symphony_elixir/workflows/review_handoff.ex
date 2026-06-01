defmodule SymphonyElixir.Workflows.ReviewHandoff do
  @moduledoc """
  Publishes requested GitHub PR review output.
  """

  alias SymphonyElixir.{Github, Storage, WorkRun}

  @processed_marker "harmony-review-processed"

  @spec publish(WorkRun.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def publish(%WorkRun{} = run, body, opts \\ []) when is_binary(body) do
    create_review = Keyword.get(opts, :create_review, &Github.Client.create_pull_request_review/5)
    append_event = Keyword.get(opts, :append_event, &Storage.append_event/1)

    case create_review.(
           run.github_owner,
           run.github_repo,
           run.github_pr_number,
           body_with_processed_marker(body, run),
           event: "COMMENT"
         ) do
      :ok ->
        case append_work_event(run, append_event) do
          :ok -> mark_dedupe_processed(run, opts)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp body_with_processed_marker(body, %WorkRun{} = run) do
    """
    #{body}

    <!-- #{@processed_marker}: #{run.dedupe_key || "unknown"} -->
    """
  end

  defp mark_dedupe_processed(%WorkRun{dedupe_key: key, payload: payload} = run, opts)
       when is_binary(key) and is_map(payload) do
    case payload_value(payload, :project_id) do
      project_id when is_binary(project_id) ->
        mark = Keyword.get(opts, :mark_dedupe_processed, &Storage.mark_dedupe_processed/1)

        %{
          project_id: project_id,
          key: key,
          scope: "github_review",
          status: "processed",
          metadata: %{"github_pr_number" => run.github_pr_number}
        }
        |> mark.()
        |> normalize_mark_result()

      _missing ->
        :ok
    end
  end

  defp mark_dedupe_processed(_run, _opts), do: :ok

  defp append_work_event(%WorkRun{id: id, payload: payload} = run, append_event)
       when is_binary(id) and is_map(payload) do
    case payload_value(payload, :project_id) do
      project_id when is_binary(project_id) ->
        %{
          project_id: project_id,
          work_run_id: run.id,
          type: "github_review_created",
          payload: %{"github_pr_number" => run.github_pr_number}
        }
        |> append_event.()
        |> normalize_mark_result()

      _missing ->
        :ok
    end
  end

  defp append_work_event(_run, _append_event), do: :ok

  defp normalize_mark_result(:ok), do: :ok
  defp normalize_mark_result({:ok, _record}), do: :ok
  defp normalize_mark_result({:error, reason}), do: {:error, reason}

  defp payload_value(%{} = payload, key), do: Map.get(payload, key) || Map.get(payload, to_string(key))
end
