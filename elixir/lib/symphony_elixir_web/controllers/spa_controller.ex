defmodule SymphonyElixirWeb.SpaController do
  @moduledoc """
  Serves the React SPA's index.html for client-side routes at the root path.
  """

  use Phoenix.Controller, formats: [:html]

  @index_path Path.join(:code.priv_dir(:symphony_elixir), "static/app/index.html")

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    case File.read(@index_path) do
      {:ok, body} ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, body)

      {:error, _reason} ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(503, "SPA not built. Run: mix assets.build")
    end
  end
end
