defmodule SymphonyElixir.RuntimePolicy.Handoff do
  @moduledoc """
  Runtime handoff operations for PR-only workflows.
  """

  alias SymphonyElixir.Tracker

  @spec move_to_human_review(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def move_to_human_review(work, state_name, opts \\ [])
      when is_map(work) and is_binary(state_name) do
    update_fun = Keyword.get(opts, :tracker_update, &Tracker.update_issue_state/2)

    case Map.get(work, :linear_issue_id) || Map.get(work, "linear_issue_id") do
      issue_id when is_binary(issue_id) and issue_id != "" -> update_fun.(issue_id, state_name)
      _missing_issue -> :ok
    end
  end
end
