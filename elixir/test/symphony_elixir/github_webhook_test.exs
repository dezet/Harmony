defmodule SymphonyElixir.GithubWebhookTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint SymphonyElixirWeb.Endpoint
  @secret "webhook-secret"

  defmodule RefreshServer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(opts), do: {:ok, %{parent: Keyword.fetch!(opts, :parent)}}

    @impl true
    def handle_call(:request_refresh, _from, state) do
      send(state.parent, :refresh_requested)

      {:reply,
       %{
         queued: true,
         coalesced: false,
         requested_at: DateTime.utc_now(),
         operations: ["poll", "reconcile"]
       }, state}
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :github_webhook_secret, @secret)
    start_test_endpoint()
    :ok
  end

  test "rejects invalid github webhook signatures" do
    payload = webhook_payload("portal")
    body = Jason.encode!(payload)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "pull_request")
      |> put_req_header("x-hub-signature-256", "sha256=bad")
      |> post("/api/v1/github/webhook", body)

    assert json_response(conn, 401)["error"]["code"] == "invalid_signature"
  end

  @tag :db
  test "stores supported github webhook event and requests refresh" do
    :ok = checkout_repo(%{})

    {:ok, project} =
      SymphonyElixir.Storage.upsert_project(%{
        slug: "portal",
        linear_project_slug: "portal-linear",
        linear_team_key: "COD",
        linear_human_review_state: "Human Review",
        github_owner: "dezet",
        github_repo: "portal",
        github_base_branch: "develop",
        config_version: 1,
        config: %{}
      })

    payload = webhook_payload("portal")
    body = Jason.encode!(payload)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "pull_request")
      |> put_req_header("x-github-delivery", "delivery-1")
      |> put_req_header("x-hub-signature-256", signature(body))
      |> post("/api/v1/github/webhook", body)

    assert json_response(conn, 202)["status"] == "accepted"
    assert_receive :refresh_requested

    [event] = SymphonyElixir.Repo.all(SymphonyElixir.Storage.WorkEvent)
    assert event.project_id == project.id
    assert event.type == "github_webhook:pull_request"
    assert event.payload["delivery"] == "delivery-1"
    assert event.payload["repository"]["name"] == "portal"
  end

  defp webhook_payload(repo) do
    %{
      "action" => "opened",
      "repository" => %{
        "name" => repo,
        "owner" => %{"login" => "dezet"}
      },
      "pull_request" => %{"number" => 7}
    }
  end

  defp signature(body) do
    digest = :crypto.mac(:hmac, :sha256, @secret, body)
    "sha256=" <> Base.encode16(digest, case: :lower)
  end

  defp start_test_endpoint do
    orchestrator_name = Module.concat(__MODULE__, :RefreshServerInstance)
    start_supervised!({RefreshServer, name: orchestrator_name, parent: self()})

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        orchestrator: orchestrator_name
      )

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
