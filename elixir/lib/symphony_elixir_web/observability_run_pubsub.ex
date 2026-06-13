defmodule SymphonyElixirWeb.ObservabilityRunPubSub do
  @moduledoc """
  PubSub helpers for per-run observability updates.

  Topic: `observability:run:<issue_id>` — one topic per live run, keyed by the
  Linear issue ID stored on the run entry.  Clients subscribe after learning the
  `issue_id` from the REST `GET /api/v1/runs/:identifier` response.
  """

  @pubsub SymphonyElixir.PubSub

  @spec topic(String.t()) :: String.t()
  def topic(issue_id), do: "observability:run:" <> issue_id

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(issue_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(issue_id))
  end

  @doc """
  Broadcast a status-changed event for the run identified by `issue_id`.

  Expected `data` keys: `identifier`, `status`, `last_error`.
  """
  @spec broadcast_status_changed(String.t(), map()) :: :ok
  def broadcast_status_changed(issue_id, %{identifier: identifier, status: status, last_error: last_error}) do
    payload = %{
      issue_id: issue_id,
      identifier: identifier,
      status: status,
      last_error: last_error,
      at: now_iso8601()
    }

    broadcast(issue_id, {:run_status_changed, payload})
  end

  @doc """
  Broadcast an event-appended notification for the run identified by `issue_id`.

  Expected `data` keys: `identifier`, `type`, `message`.
  The `item` is shaped as a live stream item (kind `"live_event"`).
  """
  @spec broadcast_event_appended(String.t(), map()) :: :ok
  def broadcast_event_appended(issue_id, %{identifier: identifier, type: type, message: message}) do
    at = now_iso8601()
    unique_suffix = Integer.to_string(:erlang.unique_integer([:positive, :monotonic]))

    payload = %{
      issue_id: issue_id,
      identifier: identifier,
      item: %{
        id: "live:" <> at <> ":" <> unique_suffix,
        kind: "live_event",
        type: type,
        at: at,
        payload: %{message: message}
      }
    }

    broadcast(issue_id, {:run_event_appended, payload})
  end

  @doc """
  Broadcast a tokens-updated notification for the run identified by `issue_id`.

  Expected `data` keys: `identifier`, `tokens` (`input_tokens`, `output_tokens`,
  `total_tokens`), `turn_count`.
  """
  @spec broadcast_tokens_updated(String.t(), map()) :: :ok
  def broadcast_tokens_updated(
        issue_id,
        %{
          identifier: identifier,
          tokens: %{input_tokens: _, output_tokens: _, total_tokens: _} = tokens,
          turn_count: turn_count
        }
      ) do
    payload = %{
      issue_id: issue_id,
      identifier: identifier,
      tokens: tokens,
      turn_count: turn_count,
      at: now_iso8601()
    }

    broadcast(issue_id, {:run_tokens_updated, payload})
  end

  @doc """
  Orchestrator convenience: broadcast `event_appended` + `tokens_updated` from
  a running-entry map that has already been updated by `integrate_codex_update`.

  Reads: `identifier`, `last_codex_event`, `last_codex_message`,
  `codex_input_tokens`, `codex_output_tokens`, `codex_total_tokens`, `turn_count`.
  """
  @spec publish_worker_update(String.t(), map()) :: :ok
  def publish_worker_update(issue_id, entry) when is_binary(issue_id) and is_map(entry) do
    identifier = Map.get(entry, :identifier, "")
    event = Map.get(entry, :last_codex_event)
    type = if is_atom(event), do: Atom.to_string(event), else: to_string(event || "update")

    message =
      case Map.get(entry, :last_codex_message) do
        %{message: msg} when is_binary(msg) and msg != "" -> msg
        _ -> type
      end

    broadcast_event_appended(issue_id, %{identifier: identifier, type: type, message: message})

    broadcast_tokens_updated(issue_id, %{
      identifier: identifier,
      tokens: %{
        input_tokens: Map.get(entry, :codex_input_tokens, 0),
        output_tokens: Map.get(entry, :codex_output_tokens, 0),
        total_tokens: Map.get(entry, :codex_total_tokens, 0)
      },
      turn_count: Map.get(entry, :turn_count, 0)
    })
  end

  @doc """
  Orchestrator convenience: broadcast `status_changed` with a plain status string
  and optional `last_error`.

  Intended for the blocked and retrying transitions.
  """
  @spec publish_run_status(String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def publish_run_status(issue_id, identifier, status, last_error)
      when is_binary(issue_id) and is_binary(status) do
    broadcast_status_changed(issue_id, %{
      identifier: identifier || "",
      status: status,
      last_error: last_error
    })
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp broadcast(issue_id, message) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, topic(issue_id), message)

      _ ->
        :ok
    end
  end

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
