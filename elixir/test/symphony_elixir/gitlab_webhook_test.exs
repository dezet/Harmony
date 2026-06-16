defmodule SymphonyElixir.GitlabWebhookTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    start_test_endpoint()
    Application.put_env(:symphony_elixir, :gitlab_webhook_secret, "s3cret")
    on_exit(fn -> Application.delete_env(:symphony_elixir, :gitlab_webhook_secret) end)
    :ok
  end

  defp post_hook(token, event, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-gitlab-token", token)
    |> put_req_header("x-gitlab-event", event)
    |> post("/api/v1/gitlab/webhook", Jason.encode!(body))
  end

  @tag :db
  test "accepts a valid token + Note Hook" do
    :ok = checkout_repo(%{})
    conn = post_hook("s3cret", "Note Hook", %{"object_kind" => "note"})
    assert json_response(conn, 200)["status"] == "accepted"
  end

  @tag :db
  test "stores the event and requests refresh when the project resolves" do
    :ok = checkout_repo(%{})

    {:ok, project} =
      SymphonyElixir.Storage.upsert_project(%{
        slug: "portal",
        linear_project_slug: "portal-linear",
        linear_team_key: "COD",
        linear_human_review_state: "Human Review",
        forge_type: "gitlab",
        forge_owner: "dezet",
        forge_repo: "portal",
        forge_base_branch: "develop",
        config_version: 1,
        config: %{}
      })

    body = %{
      "object_kind" => "note",
      "project" => %{"path_with_namespace" => "dezet/portal"}
    }

    conn = post_hook("s3cret", "Merge Request Hook", body)
    assert json_response(conn, 200)["status"] == "accepted"
    assert_receive :refresh_requested

    [event] = SymphonyElixir.Repo.all(SymphonyElixir.Storage.WorkEvent)
    assert event.project_id == project.id
    assert event.type == "gitlab_webhook:Merge Request Hook"
  end

  test "rejects a bad token with 401" do
    conn = post_hook("wrong", "Note Hook", %{})
    assert json_response(conn, 401)["error"]["code"] == "invalid_token"
  end

  test "fails closed when no secret is configured" do
    Application.delete_env(:symphony_elixir, :gitlab_webhook_secret)
    conn = post_hook("anything", "Note Hook", %{})
    assert json_response(conn, 401)["error"]["code"] == "invalid_token"
  end

  test "ignores an unsupported event" do
    conn = post_hook("s3cret", "Pipeline Hook", %{})
    assert json_response(conn, 200)["status"] == "ignored"
  end

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
