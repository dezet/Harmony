defmodule SymphonyElixirWeb.Plugs.OperatorMutation do
  @moduledoc """
  Guards operator mutations of the intake API.

  A mutating request must come from the same origin as the API, carry a JSON
  body and present the CSRF token of the current session in `X-CSRF-Token`
  (issued by `GET /api/v1/csrf`). Anything else is refused before the action
  runs. Safe methods pass through untouched.

  This is not authentication: the API stays behind the trusted network or
  proxy. Forge webhooks are not routed through this plug; they verify their
  own signatures.
  """

  @behaviour Plug

  import Plug.Conn

  alias Plug.CSRFProtection

  @safe_methods ~w(GET HEAD OPTIONS)
  @session_key "_csrf_token"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, _opts) when method in @safe_methods, do: conn

  def call(conn, _opts) do
    cond do
      not same_origin?(conn) -> reject(conn, 403, "origin_rejected", "Cross-origin mutation refused")
      not json_request?(conn) -> reject(conn, 415, "json_required", "Mutations require an application/json body")
      not valid_csrf_token?(conn) -> reject(conn, 403, "csrf_invalid", "Missing or invalid CSRF token")
      true -> conn
    end
  end

  defp same_origin?(conn) do
    with [origin] <- get_req_header(conn, "origin"),
         false <- cross_site_fetch?(conn),
         %URI{scheme: scheme, host: host, port: port} when scheme in ["http", "https"] and is_binary(host) <-
           URI.parse(origin) do
      String.downcase(host) == String.downcase(conn.host) and same_port?(scheme, port, conn)
    else
      _other -> false
    end
  end

  # Browsers that send Fetch Metadata state the relation explicitly.
  defp cross_site_fetch?(conn) do
    case get_req_header(conn, "sec-fetch-site") do
      [] -> false
      [value | _rest] -> value != "same-origin"
    end
  end

  # A TLS-terminating proxy may forward https:443 as http:80; both sides then
  # use the default port of their own scheme.
  defp same_port?(scheme, port, conn) do
    port == conn.port or (port == URI.default_port(scheme) and conn.port == URI.default_port(to_string(conn.scheme)))
  end

  defp json_request?(conn) do
    case get_req_header(conn, "content-type") do
      [content_type | _rest] ->
        content_type |> String.downcase() |> String.starts_with?("application/json")

      [] ->
        false
    end
  end

  defp valid_csrf_token?(conn) do
    conn = fetch_session(conn)
    state = conn |> get_session(@session_key) |> CSRFProtection.dump_state_from_session()

    case get_req_header(conn, "x-csrf-token") do
      [token | _rest] when is_binary(state) -> CSRFProtection.valid_state_and_csrf_token?(state, token)
      _missing -> false
    end
  end

  defp reject(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{code: code, message: message, fields: %{}}}))
    |> halt()
  end
end
