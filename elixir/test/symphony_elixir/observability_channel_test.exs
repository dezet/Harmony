defmodule SymphonyElixir.ObservabilityChannelTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ChannelTest
  import Phoenix.ConnTest

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_call(:snapshot, _from, state) do
      snapshot = %{
        running: [],
        retrying: [],
        blocked: [],
        runtime: %{},
        artifacts: [],
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        rate_limits: %{},
        projects: []
      }

      {:reply, snapshot, state}
    end
  end

  setup do
    orchestrator_name = Module.concat(__MODULE__, :Orchestrator)
    start_supervised!({FakeOrchestrator, name: orchestrator_name})
    start_test_endpoint(orchestrator_name)
    :ok
  end

  test "join replies with the current state payload" do
    {:ok, reply, _socket} = join_dashboard()

    assert %{state: %{generated_at: _, counts: %{running: 0, retrying: 0, blocked: 0}}} = reply
  end

  test "pushes a fresh state payload when observability updates" do
    {:ok, _reply, _socket} = join_dashboard()

    :ok = SymphonyElixirWeb.ObservabilityPubSub.broadcast_update()

    assert_push("state", %{generated_at: _, counts: %{running: 0}})
  end

  test "channel join state matches GET /api/v1/state (single serialization path)" do
    {:ok, %{state: channel_state}, _socket} = join_dashboard()

    api_state = json_response(get(build_conn(), "/api/v1/state"), 200)

    # generated_at is stamped per call; everything else must be identical.
    # channel_state has atom keys, the API response has string keys after JSON.
    assert stringify(Map.delete(channel_state, :generated_at)) ==
             Map.delete(api_state, "generated_at")
  end

  defp stringify(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp join_dashboard do
    SymphonyElixirWeb.UserSocket
    |> socket("user_socket", %{})
    |> subscribe_and_join(SymphonyElixirWeb.ObservabilityChannel, "observability:dashboard")
  end

  defp start_test_endpoint(orchestrator_name) do
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
