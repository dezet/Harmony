defmodule SymphonyElixirWeb.UserSocket do
  @moduledoc """
  Socket for the React client. Carries the observability channel.

  Auth seam: `connect/3` currently accepts all connections (trusted environment,
  matching the public API and `check_origin: false`). Token validation attaches here later.
  """

  use Phoenix.Socket

  channel("observability:dashboard", SymphonyElixirWeb.ObservabilityChannel)

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
