defmodule SymphonyElixir.AgentBackends.ClaudeCode do
  @moduledoc """
  Claude Code backend capability probe.

  Execution is intentionally disabled until Harmony has a verified non-interactive
  invocation contract for the installed Claude Code CLI.
  """

  @behaviour SymphonyElixir.AgentBackend

  @impl true
  @spec run(Path.t(), String.t(), map(), keyword()) :: {:error, :claude_code_execution_not_implemented}
  def run(_workspace, _prompt, _issue, _opts), do: {:error, :claude_code_execution_not_implemented}

  @impl true
  @spec capability_check(keyword()) :: :ok | {:error, :claude_code_not_found}
  def capability_check(opts) do
    find_executable = Keyword.get(opts, :find_executable, &System.find_executable/1)

    case find_executable.("claude") do
      path when is_binary(path) and path != "" -> :ok
      _missing -> {:error, :claude_code_not_found}
    end
  end
end
