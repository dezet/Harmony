defmodule SymphonyElixir.SpaServingTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    start_test_endpoint()
    :ok
  end

  test "GET /app returns the SPA index.html" do
    conn = get(build_conn(), "/app")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
    assert conn.resp_body =~ "<div id=\"root\">"
  end

  test "GET a client-side route returns index.html (SPA fallback)" do
    conn = get(build_conn(), "/app/projects/new")

    assert conn.status == 200
    assert conn.resp_body =~ "<div id=\"root\">"
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
