defmodule SymphonyElixir.RuntimePolicy.Handoff do
  @moduledoc """
  Runtime handoff operations for PR-only workflows.
  """

  alias SymphonyElixir.Tracker

  @spec move_to_human_review(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def move_to_human_review(work, state_name, opts \\ [])
      when is_map(work) and is_binary(state_name) do
    update_fun = Keyword.get(opts, :tracker_update, &Tracker.update_issue_state/2)
    artifacts = Keyword.get(opts, :artifacts, [])

    with :ok <- verify_required_evidence(work, artifacts) do
      case Map.get(work, :linear_issue_id) || Map.get(work, "linear_issue_id") do
        issue_id when is_binary(issue_id) and issue_id != "" -> update_fun.(issue_id, state_name)
        _missing_issue -> :ok
      end
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
end
