defmodule SymphonyElixir.Forge.Memory do
  @moduledoc """
  In-memory forge adapter used for tests and local development.

  Backed by a named Agent that holds seeded data and a call log.
  Call `reset/0` at the start of each test to clear state.
  """

  @behaviour SymphonyElixir.Forge

  @agent __MODULE__

  # ---------------------------------------------------------------------------
  # Agent lifecycle
  # ---------------------------------------------------------------------------

  @doc "Start the named Agent (called from test helpers or supervision)."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts \\ []) do
    Agent.start_link(&initial_state/0, name: @agent)
  end

  defp initial_state do
    %{
      repositories: [],
      change_requests: [],
      comments: [],
      calls: []
    }
  end

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  @doc "Reset all seeded data and the recorded call log."
  @spec reset() :: :ok
  def reset do
    ensure_started()
    Agent.update(@agent, fn _ -> initial_state() end)
  end

  @doc "Seed the list of repositories returned by `list_repositories/2`."
  @spec seed_repositories([map()]) :: :ok
  def seed_repositories(repos) when is_list(repos) do
    ensure_started()
    Agent.update(@agent, &Map.put(&1, :repositories, repos))
  end

  @doc "Seed the list of change requests returned by `list_change_requests/3`."
  @spec seed_change_requests([map()]) :: :ok
  def seed_change_requests(crs) when is_list(crs) do
    ensure_started()
    Agent.update(@agent, &Map.put(&1, :change_requests, crs))
  end

  @doc "Seed the comments returned by `list_change_request_comments/3`."
  @spec seed_comments([map()]) :: :ok
  def seed_comments(comments) when is_list(comments) do
    ensure_started()
    Agent.update(@agent, &Map.put(&1, :comments, comments))
  end

  @doc "Return the list of recorded calls as `{function, args}` tuples."
  @spec recorded_calls() :: [{atom(), list()}]
  def recorded_calls do
    ensure_started()
    Agent.get(@agent, &Enum.reverse(&1.calls))
  end

  # ---------------------------------------------------------------------------
  # Forge behaviour callbacks
  # ---------------------------------------------------------------------------

  @impl SymphonyElixir.Forge
  def list_repositories(creds, opts) do
    record_call(:list_repositories, [creds, opts])
    repos = Agent.get(@agent, & &1.repositories)
    {:ok, repos}
  end

  @impl SymphonyElixir.Forge
  def get_repository(creds, owner, repo) do
    record_call(:get_repository, [creds, owner, repo])
    {:ok, %{}}
  end

  @impl SymphonyElixir.Forge
  def list_change_requests(creds, repo_ref, opts) do
    record_call(:list_change_requests, [creds, repo_ref, opts])
    crs = Agent.get(@agent, & &1.change_requests)
    {:ok, crs}
  end

  @impl SymphonyElixir.Forge
  def list_pipeline_runs(creds, repo_ref, ref) do
    record_call(:list_pipeline_runs, [creds, repo_ref, ref])
    {:ok, []}
  end

  @impl SymphonyElixir.Forge
  def get_pipeline_logs(creds, repo_ref, run_id) do
    record_call(:get_pipeline_logs, [creds, repo_ref, run_id])
    {:ok, ""}
  end

  @impl SymphonyElixir.Forge
  def create_comment(creds, repo_ref, resource_id, body) do
    record_call(:create_comment, [creds, repo_ref, resource_id, body])
    :ok
  end

  @impl SymphonyElixir.Forge
  def create_review(creds, repo_ref, pr_id, body, opts) do
    record_call(:create_review, [creds, repo_ref, pr_id, body, opts])
    :ok
  end

  @impl SymphonyElixir.Forge
  def list_change_request_comments(creds, repo_ref, change_id) do
    record_call(:list_change_request_comments, [creds, repo_ref, change_id])
    {:ok, Agent.get(@agent, & &1.comments)}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp record_call(fun, args) do
    ensure_started()
    Agent.update(@agent, fn state ->
      Map.update!(state, :calls, &[{fun, args} | &1])
    end)
  end

  defp ensure_started do
    case Agent.start_link(&initial_state/0, name: @agent) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
