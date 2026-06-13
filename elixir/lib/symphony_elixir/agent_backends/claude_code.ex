defmodule SymphonyElixir.AgentBackends.ClaudeCode do
  @moduledoc """
  Claude Code backend using the CLI's non-interactive print mode.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.AgentBackends.CliCommand

  @impl true
  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, _issue, opts) do
    case CliCommand.run("claude", ["--print", "--output-format", "json", prompt], workspace, opts) do
      {:ok, {output, 0}} -> parse_success(output, opts)
      {:ok, {output, exit_status}} -> {:error, {:claude_code_failed, exit_status, String.trim(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec capability_check(keyword()) :: :ok | {:error, :claude_code_not_found}
  def capability_check(opts) do
    find_executable = Keyword.get(opts, :find_executable, &System.find_executable/1)

    case find_executable.("claude") do
      path when is_binary(path) and path != "" -> :ok
      _missing -> {:error, :claude_code_not_found}
    end
  end

  defp parse_success(output, opts) do
    case Jason.decode(output) do
      {:ok, decoded} ->
        result = Map.get(decoded, "result", output)
        session_id = Map.get(decoded, "session_id", "claude-code-session")

        CliCommand.emit(opts, %{type: :agent_output, backend: :claude_code, output: result})

        {:ok,
         %{
           session_id: session_id,
           result: result,
           raw: decoded
         }}

      {:error, reason} ->
        {:error, {:invalid_claude_code_json, reason, output}}
    end
  end
end
