defmodule SymphonyElixir.AgentBackends.Pi do
  @moduledoc """
  Pi backend capability probe.

  Execution is intentionally disabled until Harmony has a verified RPC or JSON
  event stream invocation contract for the installed Pi CLI.
  """

  @behaviour SymphonyElixir.AgentBackend

  @impl true
  @spec run(Path.t(), String.t(), map(), keyword()) :: {:error, :pi_execution_not_implemented}
  def run(_workspace, _prompt, _issue, _opts), do: {:error, :pi_execution_not_implemented}

  @impl true
  @spec capability_check(keyword()) :: :ok | {:error, :pi_not_found}
  def capability_check(opts) do
    find_executable = Keyword.get(opts, :find_executable, &System.find_executable/1)

    case find_executable.("pi") do
      path when is_binary(path) and path != "" -> :ok
      _missing -> {:error, :pi_not_found}
    end
  end
end
