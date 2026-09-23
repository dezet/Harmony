defmodule SymphonyElixirWeb.CsrfController do
  @moduledoc """
  Issues the session CSRF token the SPA needs for operator mutations.

  The token lives only in memory of the browser client; it is never embedded
  in the static `index.html` and the response is never cached.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.IntakePresenter

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{csrf_token: Plug.CSRFProtection.get_csrf_token()})
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params), do: IntakePresenter.render_error(conn, :method_not_allowed)
end
