defmodule SymphonyElixirWeb.RunChannel do
  @moduledoc """
  Per-run observability channel.

  Joins `observability:run:<issue_id>` and forwards the three granular events
  (`status_changed`, `event_appended`, `tokens_updated`) to the React client.

  Initial state is seeded by the REST endpoint (`GET /api/v1/runs/:identifier`);
  the channel carries only incremental updates — no payload is sent on join.
  """

  use Phoenix.Channel

  alias SymphonyElixirWeb.ObservabilityRunPubSub

  @impl true
  def join("observability:run:" <> issue_id, _params, socket) do
    :ok = ObservabilityRunPubSub.subscribe(issue_id)
    socket = assign(socket, :issue_id, issue_id)
    {:ok, socket}
  end

  @impl true
  def handle_info({:run_status_changed, payload}, socket) do
    push(socket, "status_changed", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:run_event_appended, payload}, socket) do
    push(socket, "event_appended", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:run_tokens_updated, payload}, socket) do
    push(socket, "tokens_updated", payload)
    {:noreply, socket}
  end
end
