defmodule SymphonyElixir.RunChannelTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ChannelTest

  @endpoint SymphonyElixirWeb.Endpoint

  # ---------------------------------------------------------------------------
  # A minimal fake orchestrator is needed because starting the Endpoint also
  # boots ObservabilityChannel infrastructure that calls the orchestrator.
  # ---------------------------------------------------------------------------
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

  # ---------------------------------------------------------------------------
  # Join
  # ---------------------------------------------------------------------------

  test "successful join on observability:run:abc123 replies :ok with no payload" do
    assert {:ok, _reply, socket} = join_run("abc123")
    assert socket.assigns.issue_id == "abc123"
  end

  # ---------------------------------------------------------------------------
  # status_changed broadcast
  # ---------------------------------------------------------------------------

  test "broadcast_status_changed pushes status_changed with correct payload" do
    {:ok, _reply, _socket} = join_run("issue-1")

    SymphonyElixirWeb.ObservabilityRunPubSub.broadcast_status_changed("issue-1", %{
      identifier: "HAR-42",
      status: "blocked",
      last_error: "timeout"
    })

    assert_push("status_changed", payload)
    assert payload.issue_id == "issue-1"
    assert payload.identifier == "HAR-42"
    assert payload.status == "blocked"
    assert payload.last_error == "timeout"
    assert is_binary(payload.at)
  end

  # ---------------------------------------------------------------------------
  # event_appended broadcast
  # ---------------------------------------------------------------------------

  test "broadcast_event_appended pushes event_appended with correct item shape" do
    {:ok, _reply, _socket} = join_run("issue-2")

    SymphonyElixirWeb.ObservabilityRunPubSub.broadcast_event_appended("issue-2", %{
      identifier: "HAR-43",
      type: "agent_turn",
      message: "Agent completed turn 3"
    })

    assert_push("event_appended", payload)
    assert payload.issue_id == "issue-2"
    assert payload.identifier == "HAR-43"

    item = payload.item
    assert is_binary(item.id)
    assert String.starts_with?(item.id, "live:")
    assert item.kind == "live_event"
    assert item.type == "agent_turn"
    assert is_binary(item.at)
    assert item.payload.message == "Agent completed turn 3"
  end

  # ---------------------------------------------------------------------------
  # tokens_updated broadcast
  # ---------------------------------------------------------------------------

  test "broadcast_tokens_updated pushes tokens_updated with correct payload" do
    {:ok, _reply, _socket} = join_run("issue-3")

    SymphonyElixirWeb.ObservabilityRunPubSub.broadcast_tokens_updated("issue-3", %{
      identifier: "HAR-44",
      tokens: %{input_tokens: 100, output_tokens: 200, total_tokens: 300},
      turn_count: 5
    })

    assert_push("tokens_updated", payload)
    assert payload.issue_id == "issue-3"
    assert payload.identifier == "HAR-44"
    assert payload.tokens.input_tokens == 100
    assert payload.tokens.output_tokens == 200
    assert payload.tokens.total_tokens == 300
    assert payload.turn_count == 5
    assert is_binary(payload.at)
  end

  # ---------------------------------------------------------------------------
  # Topic isolation — broadcast for a DIFFERENT issue_id must NOT be pushed
  # ---------------------------------------------------------------------------

  test "broadcast for a different issue_id is not pushed to this channel" do
    {:ok, _reply, _socket} = join_run("issue-mine")

    SymphonyElixirWeb.ObservabilityRunPubSub.broadcast_status_changed("issue-other", %{
      identifier: "HAR-99",
      status: "running",
      last_error: nil
    })

    refute_push("status_changed", _)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp join_run(issue_id) do
    SymphonyElixirWeb.UserSocket
    |> socket("user_socket", %{})
    |> subscribe_and_join(SymphonyElixirWeb.RunChannel, "observability:run:" <> issue_id)
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
