defmodule SymphonyElixir.Workflows.AddressReviewPrompt do
  @moduledoc """
  Builds the agent prompt for an `address_review` run: the unresolved review
  threads plus the structured-output contract the handoff consumes.
  """

  alias SymphonyElixir.WorkRun

  @spec build(WorkRun.t()) :: String.t()
  def build(%WorkRun{payload: payload}) do
    threads = (is_map(payload) && (payload["threads"] || payload[:threads])) || []

    """
    Reviewers left unresolved comments on this change. Address each thread in code,
    commit the fixes, then report your per-thread outcome.

    Threads:
    #{Enum.map_join(threads, "\n", &thread_line/1)}

    When done, output a single JSON object as the last line, exactly this shape:

    {"threads": [{"thread_id": "<id>", "reply": "<short reply to the reviewer>", "resolved": true}]}

    Set "resolved" to true only for threads you actually addressed in this change.
    Reply concisely, referencing what you changed.
    """
  end

  defp thread_line(thread) do
    id = mget(thread, :id)
    path = mget(thread, :path)
    line = mget(thread, :line)
    body = thread |> mget(:comments) |> latest_body()
    "- thread_id=#{id} (#{path}:#{line}): #{body}"
  end

  defp latest_body(comments) when is_list(comments) and comments != [] do
    comments |> List.last() |> mget(:body)
  end

  defp latest_body(_), do: ""

  defp mget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp mget(_map, _key), do: nil
end
