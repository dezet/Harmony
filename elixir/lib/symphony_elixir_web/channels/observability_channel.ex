defmodule SymphonyElixirWeb.ObservabilityChannel do
  @moduledoc """
  Pushes the observability `state_payload` to React clients: once on join, then on
  every `:observability_updated` PubSub broadcast. Reuses `Presenter.state_payload/2`
  so the wire shape is identical to `GET /api/v1/state`.
  """

  use Phoenix.Channel

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @impl true
  def join("observability:dashboard", _payload, socket) do
    :ok = ObservabilityPubSub.subscribe()
    {:ok, %{state: state_payload()}, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    push(socket, "state", state_payload())
    {:noreply, socket}
  end

  defp state_payload, do: Presenter.state_payload(orchestrator(), snapshot_timeout_ms())

  defp orchestrator, do: Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator

  defp snapshot_timeout_ms, do: Endpoint.config(:snapshot_timeout_ms) || 15_000
end
