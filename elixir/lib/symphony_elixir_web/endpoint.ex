defmodule SymphonyElixirWeb.Endpoint do
  @moduledoc """
  Phoenix endpoint for Symphony's optional observability UI and API.
  """

  use Phoenix.Endpoint, otp_app: :symphony_elixir

  @session_options [
    store: :cookie,
    key: "_symphony_elixir_key",
    signing_salt: "symphony-session"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  # Socket for the React client (observability dashboard channel).
  socket("/socket", SymphonyElixirWeb.UserSocket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  # Serves the built React SPA (Vite output) under /app during Phases 0-2.
  # Phase 3 cutover flips this to "/".
  plug(Plug.Static,
    at: "/app",
    from: {:symphony_elixir, "priv/static/app"},
    gzip: false,
    only: ~w(assets index.html favicon.svg icons.svg)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    body_reader: {__MODULE__, :cache_raw_body, []}
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(SymphonyElixirWeb.Router)

  @spec cache_raw_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def cache_raw_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, append_raw_body(conn, body)}
      {:more, body, conn} -> {:more, body, append_raw_body(conn, body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_raw_body(conn, body) do
    Plug.Conn.assign(conn, :raw_body, [body | Map.get(conn.assigns, :raw_body, [])])
  end
end
