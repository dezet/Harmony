defmodule SymphonyElixirWeb.IntakeChannel do
  @moduledoc """
  Case Center invalidation channel (spec §11.4) on `intake:workspace`.

  Join carries no data. Each committed intake change is pushed as `changed`
  with the whitelisted payload of `IntakePubSub.payload/1`; clients invalidate
  the matching React Query keys and refetch details over REST.
  """

  use Phoenix.Channel

  alias SymphonyElixirWeb.IntakePubSub

  # Like the observability channels: no authorization in the trusted deployment
  # (see UserSocket); the payload never carries content, only identifiers.
  @impl true
  def join("intake:workspace", _params, socket) do
    :ok = IntakePubSub.subscribe()
    {:ok, socket}
  end

  @impl true
  def handle_info({:intake_changed, payload}, socket) do
    push(socket, "changed", payload)
    {:noreply, socket}
  end
end
