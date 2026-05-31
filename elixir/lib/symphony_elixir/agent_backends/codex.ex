defmodule SymphonyElixir.AgentBackends.Codex do
  @moduledoc """
  Codex app-server implementation of the agent backend contract.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.Codex.AppServer

  @impl true
  def run(workspace, prompt, issue, opts \\ []) do
    {run, opts} = Keyword.pop(opts, :run, &AppServer.run/4)
    run.(workspace, prompt, issue, opts)
  end

  @impl true
  def capability_check(_opts), do: :ok

  @spec start_session(Path.t(), keyword()) :: {:ok, AppServer.session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    {start_session, opts} = Keyword.pop(opts, :start_session, &AppServer.start_session/2)
    start_session.(workspace, opts)
  end

  @spec run_turn(AppServer.session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    {run_turn, opts} = Keyword.pop(opts, :run_turn, &AppServer.run_turn/4)
    run_turn.(session, prompt, issue, opts)
  end

  @spec stop_session(AppServer.session(), keyword()) :: :ok
  def stop_session(session, opts \\ []) do
    {stop_session, _opts} = Keyword.pop(opts, :stop_session, &AppServer.stop_session/1)
    stop_session.(session)
  end
end
