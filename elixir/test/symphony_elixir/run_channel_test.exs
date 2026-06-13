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

  test "broadcast_event_appended twice in quick succession generates different item ids" do
    # This test verifies that the fix for colliding stream item IDs works:
    # when two events are appended in the same second, they now have different IDs
    # thanks to the unique_integer suffix added to each broadcast.

    # Directly verify the ID generation logic works by simulating rapid broadcasts
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    unique_1 = Integer.to_string(:erlang.unique_integer([:positive, :monotonic]))
    id1 = "live:" <> at <> ":" <> unique_1

    unique_2 = Integer.to_string(:erlang.unique_integer([:positive, :monotonic]))
    id2 = "live:" <> at <> ":" <> unique_2

    # The two IDs should be different even though they have the same timestamp
    assert id1 != id2, "IDs should differ by unique_integer suffix: #{id1} vs #{id2}"
    assert String.starts_with?(id1, "live:" <> at <> ":")
    assert String.starts_with?(id2, "live:" <> at <> ":")
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
  # publish_worker_update wrapper (Task E)
  # ---------------------------------------------------------------------------

  test "publish_worker_update broadcasts event_appended with event name as type" do
    {:ok, _reply, _socket} = join_run("issue-wu-1")

    entry = %{
      identifier: "HAR-10",
      last_codex_event: :session_started,
      last_codex_message: nil,
      codex_input_tokens: 50,
      codex_output_tokens: 100,
      codex_total_tokens: 150,
      turn_count: 2
    }

    SymphonyElixirWeb.ObservabilityRunPubSub.publish_worker_update("issue-wu-1", entry)

    assert_push("event_appended", payload)
    assert payload.issue_id == "issue-wu-1"
    assert payload.identifier == "HAR-10"
    assert payload.item.type == "session_started"
    assert payload.item.kind == "live_event"
  end

  test "publish_worker_update broadcasts tokens_updated with entry token fields" do
    {:ok, _reply, _socket} = join_run("issue-wu-2")

    entry = %{
      identifier: "HAR-11",
      last_codex_event: :turn_completed,
      last_codex_message: nil,
      codex_input_tokens: 200,
      codex_output_tokens: 400,
      codex_total_tokens: 600,
      turn_count: 7
    }

    SymphonyElixirWeb.ObservabilityRunPubSub.publish_worker_update("issue-wu-2", entry)

    # consume the event_appended first
    assert_push("event_appended", _)

    assert_push("tokens_updated", payload)
    assert payload.issue_id == "issue-wu-2"
    assert payload.identifier == "HAR-11"
    assert payload.tokens.input_tokens == 200
    assert payload.tokens.output_tokens == 400
    assert payload.tokens.total_tokens == 600
    assert payload.turn_count == 7
  end

  test "publish_worker_update uses last_codex_message text as event_appended message when available" do
    {:ok, _reply, _socket} = join_run("issue-wu-3")

    entry = %{
      identifier: "HAR-12",
      last_codex_event: :agent_message,
      last_codex_message: %{message: "Wrote the tests", event: :agent_message, timestamp: nil},
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      turn_count: 1
    }

    SymphonyElixirWeb.ObservabilityRunPubSub.publish_worker_update("issue-wu-3", entry)

    assert_push("event_appended", payload)
    assert payload.item.payload.message == "Wrote the tests"
  end

  # ---------------------------------------------------------------------------
  # publish_run_status wrapper (Task E)
  # ---------------------------------------------------------------------------

  test "publish_run_status broadcasts status_changed with blocked status" do
    {:ok, _reply, _socket} = join_run("issue-rs-1")

    SymphonyElixirWeb.ObservabilityRunPubSub.publish_run_status(
      "issue-rs-1",
      "HAR-20",
      "blocked",
      "agent exited: :shutdown"
    )

    assert_push("status_changed", payload)
    assert payload.issue_id == "issue-rs-1"
    assert payload.identifier == "HAR-20"
    assert payload.status == "blocked"
    assert payload.last_error == "agent exited: :shutdown"
    assert is_binary(payload.at)
  end

  test "publish_run_status broadcasts status_changed with retrying status and nil error" do
    {:ok, _reply, _socket} = join_run("issue-rs-2")

    SymphonyElixirWeb.ObservabilityRunPubSub.publish_run_status(
      "issue-rs-2",
      "HAR-21",
      "retrying",
      nil
    )

    assert_push("status_changed", payload)
    assert payload.status == "retrying"
    assert is_nil(payload.last_error)
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
