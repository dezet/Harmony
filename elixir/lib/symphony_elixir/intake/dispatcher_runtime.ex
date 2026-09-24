defmodule SymphonyElixir.Intake.DispatcherRuntime do
  @moduledoc """
  Runs `Intake.Dispatcher.dispatch_one/2` from the durable outbox once per tick.

  Two separate pools bound local concurrency: up to four I/O effects and one
  analysis. Each worker claims at most one delivery, so a tick starts only as
  many workers as its pool has free slots. The Outbox enforces the same limits
  across nodes with its own advisory locks and lease counts.

  Every tick rereads the runtime switches. New I/O claims require intake and
  effects; new analyses additionally require `analysis.enabled`. Workers already
  running finish and persist their result through the lease CAS. Failures are
  isolated per worker and logged as safe codes; nothing is kept in memory, so
  the next tick reads the outbox again.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Intake
  alias SymphonyElixir.Intake.Dispatcher

  @tick_interval_ms 1_000
  @pool_limits %{io: 4, analysis: 1}

  @type server :: GenServer.server()
  @type pool :: :io | :analysis
  @type started :: %{io: non_neg_integer(), analysis: non_neg_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc "Starts workers for free pool slots now; returns how many started per pool."
  @spec tick(server()) :: {:ok, started()}
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @impl GenServer
  def init(opts) do
    state = %{
      dispatch_fun: dispatch_fun(opts),
      dispatch_opts: Keyword.get(opts, :dispatch_opts, []),
      clock: Keyword.get(opts, :clock),
      tick_interval_ms: Keyword.get(opts, :tick_interval_ms, @tick_interval_ms),
      enabled?: Keyword.get(opts, :enabled?, &Intake.enabled?/0),
      effects_enabled?: Keyword.get(opts, :effects_enabled?, &Intake.effects_enabled?/0),
      analysis_enabled?: Keyword.get(opts, :analysis_enabled?, &Intake.analysis_enabled?/0),
      task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor),
      result_observer: Keyword.get(opts, :result_observer),
      running: %{}
    }

    schedule_tick(state.tick_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:tick, _from, state) do
    {started, state} = start_workers(state)
    {:reply, {:ok, started}, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    {_started, state} = start_workers(state)
    schedule_tick(state.tick_interval_ms)
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.running, ref) do
      {nil, _running} ->
        {:noreply, state}

      {pool, running} ->
        Process.demonitor(ref, [:flush])
        report_result(pool, result)
        notify_result_observer(state, pool, result)
        {:noreply, %{state | running: running}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.running, ref) do
      {nil, _running} ->
        {:noreply, state}

      {pool, running} ->
        error_code = exit_code(reason)
        Logger.warning("Jira intake dispatch worker exited pool=#{pool} error_code=#{error_code}")
        notify_result_observer(state, pool, {:error, error_code})
        {:noreply, %{state | running: running}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_workers(state) do
    switches = read_switches(state)

    Enum.reduce([:io, :analysis], {%{io: 0, analysis: 0}, state}, fn pool, {started, current} ->
      if pool_enabled?(pool, switches) do
        {count, next} = fill_pool(current, pool)
        {Map.put(started, pool, count), next}
      else
        {started, current}
      end
    end)
  end

  defp fill_pool(state, pool) do
    free = max(Map.fetch!(@pool_limits, pool) - running_count(state, pool), 0)
    {free, Enum.reduce(1..free//1, state, fn _slot, acc -> start_worker(acc, pool) end)}
  end

  defp pool_enabled?(:io, switches), do: switches.intake and switches.effects
  defp pool_enabled?(:analysis, switches), do: switches.intake and switches.effects and switches.analysis

  defp start_worker(state, pool) do
    opts = worker_opts(state, pool)
    dispatch_fun = state.dispatch_fun

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        dispatch_safely(dispatch_fun, opts)
      end)

    put_in(state, [:running, task.ref], pool)
  end

  # The I/O pool excludes analysis through the Outbox switch filter; the analysis
  # pool claims only analysis deliveries.
  defp worker_opts(state, :io) do
    state
    |> base_worker_opts()
    |> Keyword.merge(intake_enabled: true, effects_enabled: true, analysis_enabled: false)
  end

  defp worker_opts(state, :analysis) do
    state
    |> base_worker_opts()
    |> Keyword.merge(intake_enabled: true, effects_enabled: true, analysis_enabled: true, operation: "analysis")
  end

  defp base_worker_opts(%{clock: clock, dispatch_opts: opts}) when is_function(clock, 0),
    do: Keyword.put(opts, :clock, clock)

  defp base_worker_opts(%{dispatch_opts: opts}), do: opts

  defp dispatch_safely(dispatch_fun, opts) do
    dispatch_fun.(opts)
  rescue
    _exception -> {:error, :dispatch_failed}
  catch
    _kind, _reason -> {:error, :dispatch_failed}
  end

  defp dispatch_fun(opts) do
    case {Keyword.get(opts, :dispatch_fun), Keyword.get(opts, :adapter)} do
      {fun, _adapter} when is_function(fun, 1) -> fun
      {nil, nil} -> &Dispatcher.dispatch_one/1
      {nil, adapter} -> fn dispatch_opts -> Dispatcher.dispatch_one(adapter, dispatch_opts) end
    end
  end

  defp read_switches(state) do
    %{
      intake: switch_enabled?(state.enabled?),
      effects: switch_enabled?(state.effects_enabled?),
      analysis: switch_enabled?(state.analysis_enabled?)
    }
  rescue
    _exception -> switches_unavailable()
  catch
    :exit, _reason -> switches_unavailable()
  end

  # Unreadable configuration blocks new claims; it never falls back to "enabled".
  defp switches_unavailable do
    Logger.warning("Jira intake dispatch skipped error_code=invalid_intake_settings")
    %{intake: false, effects: false, analysis: false}
  end

  defp switch_enabled?(fun) when is_function(fun, 0), do: fun.() == true
  defp switch_enabled?(value), do: value == true

  defp running_count(state, pool), do: Enum.count(state.running, fn {_ref, running_pool} -> running_pool == pool end)

  defp report_result(pool, {:error, reason}) do
    Logger.warning("Jira intake dispatch failed pool=#{pool} error_code=#{error_code(reason)}")
  end

  defp report_result(_pool, _result), do: :ok

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "dispatch_failed"

  defp exit_code(:killed), do: :killed
  defp exit_code(_reason), do: :worker_crashed

  defp notify_result_observer(%{result_observer: observer}, pool, result) when is_function(observer, 2),
    do: observer.(pool, result)

  defp notify_result_observer(_state, _pool, _result), do: :ok

  defp schedule_tick(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp schedule_tick(_interval_ms), do: :ok
end
