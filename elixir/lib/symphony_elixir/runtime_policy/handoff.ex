defmodule SymphonyElixir.RuntimePolicy.Handoff do
  @moduledoc """
  Runtime handoff operations for PR-only workflows.
  """

  alias SymphonyElixir.{Storage, Tracker}

  @spec move_to_human_review(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def move_to_human_review(work, state_name, opts \\ [])
      when is_map(work) and is_binary(state_name) do
    update_fun = Keyword.get(opts, :tracker_update, &Tracker.update_issue_state/2)
    append_event = Keyword.get(opts, :append_event, &Storage.append_event/1)
    artifacts = Keyword.get(opts, :artifacts, [])

    with :ok <- verify_required_evidence(work, artifacts),
         {:ok, issue_id} <- linear_issue_id(work),
         :ok <- update_fun.(issue_id, state_name) do
      append_work_event(work, append_event, "linear_state_updated", %{
        "linear_issue_id" => issue_id,
        "state" => state_name
      })
    else
      :missing_issue -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec verify_required_evidence(map(), [map()]) :: :ok | {:error, term()}
  def verify_required_evidence(run, artifacts) when is_map(run) and is_list(artifacts) do
    required = Map.get(run, :required_evidence, []) || Map.get(run, "required_evidence", [])

    missing =
      required
      |> Enum.reject(fn
        "browser" -> Enum.any?(artifacts, &(artifact_kind(&1) in ["screenshot", "trace", "report"]))
        _other -> false
      end)

    if missing == [], do: :ok, else: {:error, {:missing_required_evidence, missing}}
  end

  defp artifact_kind(%{} = artifact), do: Map.get(artifact, :kind) || Map.get(artifact, "kind")

  defp linear_issue_id(work) do
    case Map.get(work, :linear_issue_id) || Map.get(work, "linear_issue_id") do
      issue_id when is_binary(issue_id) and issue_id != "" -> {:ok, issue_id}
      _missing_issue -> :missing_issue
    end
  end

  defp append_work_event(work, append_event, type, payload) do
    case Map.get(work, :project_id) || Map.get(work, "project_id") || payload_project_id(work) do
      project_id when is_binary(project_id) ->
        %{
          project_id: project_id,
          work_run_id: Map.get(work, :id) || Map.get(work, "id") || Map.get(work, :work_run_id) || Map.get(work, "work_run_id"),
          type: type,
          payload: payload
        }
        |> append_event.()
        |> normalize_event_result()

      _missing_project ->
        :ok
    end
  end

  defp payload_project_id(work) do
    case Map.get(work, :payload) || Map.get(work, "payload") do
      %{} = payload -> Map.get(payload, :project_id) || Map.get(payload, "project_id")
      _other -> nil
    end
  end

  defp normalize_event_result(:ok), do: :ok
  defp normalize_event_result({:ok, _event}), do: :ok
  defp normalize_event_result({:error, reason}), do: {:error, reason}
end
