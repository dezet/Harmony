defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Behaviour and resolver for agent execution backends.
  """

  alias SymphonyElixir.AgentBackends

  @type backend_module :: module()

  @callback run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback capability_check(keyword()) :: :ok | {:error, term()}

  @spec resolve(module() | atom() | String.t()) :: {:ok, backend_module()} | {:error, term()}
  def resolve(module) when is_atom(module) and not is_nil(module) do
    if function_exported?(module, :run, 4) do
      {:ok, module}
    else
      module
      |> Atom.to_string()
      |> resolve()
    end
  end

  def resolve(name) when is_binary(name) do
    case String.trim(name) do
      "codex" -> {:ok, AgentBackends.Codex}
      "claude_code" -> {:ok, AgentBackends.ClaudeCode}
      "pi" -> {:ok, AgentBackends.Pi}
      other -> {:error, {:unsupported_agent_backend, other}}
    end
  end

  @spec resolve!(module() | atom() | String.t()) :: backend_module()
  def resolve!(backend) do
    case resolve(backend) do
      {:ok, module} -> module
      {:error, reason} -> raise ArgumentError, "Invalid agent backend: #{inspect(reason)}"
    end
  end
end
