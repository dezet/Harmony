defmodule SymphonyElixir.AgentBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentBackend, AgentRunner}
  alias SymphonyElixir.AgentBackends.{ClaudeCode, Codex, Pi}
  alias SymphonyElixir.Linear.Issue

  defmodule FakeBackend do
    @behaviour AgentBackend

    @impl true
    def run(workspace, prompt, issue, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:backend_run, workspace, prompt, issue})
      {:ok, %{session_id: "fake-session"}}
    end

    @impl true
    def capability_check(_opts), do: :ok
  end

  test "codex backend delegates to app server run" do
    parent = self()

    run = fn workspace, prompt, issue, opts ->
      send(parent, {:codex_run, workspace, prompt, issue, opts})
      {:ok, %{session_id: "thread-turn"}}
    end

    backend = Codex
    issue = %Issue{id: "issue-1", identifier: "COD-5", title: "Smoke"}

    assert {:ok, %{session_id: "thread-turn"}} =
             backend.run("/tmp/workspace", "prompt", issue, run: run, metadata: "kept")

    assert_received {:codex_run, "/tmp/workspace", "prompt", ^issue, opts}
    assert Keyword.fetch!(opts, :metadata) == "kept"
    refute Keyword.has_key?(opts, :run)
  end

  test "resolves configured backend names" do
    assert {:ok, Codex} = AgentBackend.resolve("codex")
    assert {:ok, ClaudeCode} = AgentBackend.resolve("claude_code")
    assert {:ok, Pi} = AgentBackend.resolve("pi")
    assert {:error, {:unsupported_agent_backend, "unknown"}} = AgentBackend.resolve("unknown")
  end

  test "agent runner can execute through a configured backend" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-backend-runner-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        identifier: "MT-BACKEND",
        title: "Run through backend",
        description: "Exercise AgentBackend routing",
        state: "In Progress"
      }

      assert :ok =
               AgentRunner.run(issue, nil,
                 agent_backend: FakeBackend,
                 prompt: "backend prompt for MT-BACKEND",
                 test_pid: self()
               )

      assert_receive {:backend_run, workspace, prompt, ^issue}
      assert workspace == Path.join(workspace_root, "MT-BACKEND")
      assert prompt == "backend prompt for MT-BACKEND"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "claude code backend reports missing executable" do
    find_executable = fn "claude" -> nil end

    assert {:error, :claude_code_not_found} =
             ClaudeCode.capability_check(find_executable: find_executable)
  end

  test "claude code backend reports available executable" do
    find_executable = fn "claude" -> "/usr/local/bin/claude" end

    assert :ok =
             ClaudeCode.capability_check(find_executable: find_executable)
  end

  test "claude code backend does not execute work before invocation contract is implemented" do
    issue = %Issue{id: "issue-claude", identifier: "COD-CLAUDE", title: "Claude spike"}

    assert {:error, :claude_code_execution_not_implemented} =
             ClaudeCode.run("/tmp/workspace", "prompt", issue, [])
  end

  test "pi backend reports missing executable" do
    find_executable = fn "pi" -> nil end

    assert {:error, :pi_not_found} =
             Pi.capability_check(find_executable: find_executable)
  end

  test "pi backend reports available executable" do
    find_executable = fn "pi" -> "/usr/local/bin/pi" end

    assert :ok =
             Pi.capability_check(find_executable: find_executable)
  end

  test "pi backend does not execute work before invocation contract is implemented" do
    issue = %Issue{id: "issue-pi", identifier: "COD-PI", title: "Pi spike"}

    assert {:error, :pi_execution_not_implemented} =
             Pi.run("/tmp/workspace", "prompt", issue, [])
  end
end
