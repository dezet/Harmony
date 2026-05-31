defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application
  require Logger
  alias SymphonyElixir.ProjectConfig.Sync

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    children = [
      SymphonyElixir.Repo,
      {Task, fn -> sync_project_configs() end},
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.Orchestrator,
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  defp sync_project_configs do
    case Sync.sync_default_dir() do
      :ok -> :ok
      {:error, reason} -> Logger.error("Project config sync failed: #{inspect(reason)}")
    end
  end
end
