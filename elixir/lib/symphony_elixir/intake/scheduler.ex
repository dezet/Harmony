defmodule SymphonyElixir.Intake.Scheduler do
  @moduledoc "Schedules durable Jira intake scans from each rule's persisted due time."

  use GenServer
  import Ecto.Query
  require Logger

  alias SymphonyElixir.Intake
  alias SymphonyElixir.Intake.Poller
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.AutomationRule

  @tick_interval_ms 5_000
  @max_concurrent_scans 2
  @safe_error_codes ~w(
    analysis_profile_unavailable
    invalid_jira_connection
    jira_connection_disabled
    jira_credentials_unset
    jira_scan_failed
    malformed_issue
    not_found
    rule_not_active
    scan_capacity
    scan_in_progress
    scan_limit_exceeded
    stale_generation
    effects_disabled
  )

  @type server :: GenServer.server()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @spec tick(server(), keyword()) :: {:ok, [binary()]}
  def tick(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:tick, opts})
  end

  @doc """
  Starts a manual scan. With the default `Poller` the scan is claimed
  synchronously (rule lease plus a running scan record) and its ID returned;
  Jira is read afterwards in a supervised task. A custom poller function
  cannot claim ahead, so its scan ID is `nil`.
  """
  @spec check_now(server(), binary()) :: {:accepted, binary() | nil} | {:error, atom()}
  def check_now(server \\ __MODULE__, rule_id) when is_binary(rule_id) do
    GenServer.call(server, {:check_now, rule_id})
  end

  @impl GenServer
  def init(opts) do
    state = %{
      poller: Keyword.get(opts, :poller, Poller),
      run_opts: Keyword.get(opts, :run_opts, []),
      tick_interval_ms: Keyword.get(opts, :tick_interval_ms, @tick_interval_ms),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      enabled?: Keyword.get(opts, :enabled?, &Intake.enabled?/0),
      effects_enabled?: Keyword.get(opts, :effects_enabled?, &Intake.effects_enabled?/0),
      result_observer: Keyword.get(opts, :result_observer),
      running: %{}
    }

    schedule_tick(state.tick_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:tick, opts}, _from, state) do
    if intake_enabled?(state) and effects_enabled?(state) do
      now = Keyword.get(opts, :now, state.clock.())
      {rule_ids, next_state} = start_due_scans(state, now)
      {:reply, {:ok, rule_ids}, next_state}
    else
      {:reply, {:ok, []}, state}
    end
  end

  def handle_call({:check_now, rule_id}, _from, state) do
    now = state.clock.()

    case check_now_error(state, rule_id) do
      nil -> check_now_rule(state, rule_id, now)
      error -> {:reply, {:error, error}, state}
    end
  end

  defp check_now_error(state, rule_id) do
    cond do
      not intake_enabled?(state) -> :intake_disabled
      not effects_enabled?(state) -> :effects_disabled
      rule_running?(state, rule_id) -> :scan_in_progress
      map_size(state.running) >= @max_concurrent_scans -> :scan_in_progress
      true -> nil
    end
  end

  defp check_now_rule(state, rule_id, now) do
    case Repo.get(AutomationRule, rule_id) do
      nil -> {:reply, {:error, :not_found}, state}
      %AutomationRule{} = rule -> check_now_active_rule(state, rule, now)
    end
  end

  defp check_now_active_rule(state, rule, now) do
    cond do
      not active?(rule) -> {:reply, {:error, :rule_not_active}, state}
      lease_active?(rule, now) -> {:reply, {:error, :scan_in_progress}, state}
      claims_ahead?(state.poller) -> claim_and_start(state, rule.id)
      true -> {:reply, {:accepted, nil}, start_scan_task(state, rule.id)}
    end
  end

  defp claim_and_start(state, rule_id) do
    case state.poller.start(rule_id, state.run_opts) do
      {:ok, context} ->
        task = supervised_task(fn -> resume_safely(state.poller, context, state.run_opts) end)
        {:reply, {:accepted, context.scan.id}, put_in(state, [:running, task.ref], %{rule_id: rule_id, pid: task.pid})}

      {:error, reason} ->
        {:reply, {:error, claim_error(reason)}, state}
    end
  rescue
    _exception -> {:reply, {:error, :scan_failed}, state}
  catch
    :exit, _reason -> {:reply, {:error, :scan_failed}, state}
  end

  defp claims_ahead?(poller) when is_atom(poller) do
    Code.ensure_loaded?(poller) and function_exported?(poller, :start, 2) and function_exported?(poller, :resume, 2)
  end

  defp claims_ahead?(_poller), do: false

  defp claim_error(reason) when reason in [:scan_in_progress, :scan_capacity, :rule_not_active, :not_found, :effects_disabled],
    do: reason

  defp claim_error(_reason), do: :scan_failed

  @impl GenServer
  def handle_info(:tick, state) do
    state =
      if intake_enabled?(state) and effects_enabled?(state) do
        {_rule_ids, state} = start_due_scans(state, state.clock.())
        state
      else
        state
      end

    schedule_tick(state.tick_interval_ms)
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.running, ref) do
      {nil, running} ->
        {:noreply, %{state | running: running}}

      {%{rule_id: rule_id}, running} ->
        Process.demonitor(ref, [:flush])
        error_code = report_scan_result(rule_id, result)
        notify_result_observer(state, rule_id, error_code)
        {:noreply, %{state | running: running}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.running, ref) do
      {nil, running} ->
        {:noreply, %{state | running: running}}

      {%{rule_id: rule_id}, running} ->
        if reason != :normal do
          error_code = safe_error_code(reason)
          Logger.warning("Jira intake scan worker exited rule_id=#{rule_id} error_code=#{error_code}")
          notify_result_observer(state, rule_id, error_code)
        end

        {:noreply, %{state | running: running}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_due_scans(state, now) do
    slots = @max_concurrent_scans - map_size(state.running)

    if slots <= 0 do
      {[], state}
    else
      due_rule_ids = due_rule_ids(now, running_rule_ids(state), slots)

      Enum.reduce(due_rule_ids, {[], state}, fn rule_id, {started, current_state} ->
        {started ++ [rule_id], start_scan_task(current_state, rule_id)}
      end)
    end
  end

  defp due_rule_ids(now, running_ids, limit) do
    Repo.all(
      from(rule in AutomationRule,
        where:
          rule.id not in ^running_ids and
            (rule.enabled or (not rule.enabled and rule.activation_status == "activating")) and
            (is_nil(rule.next_poll_at) or rule.next_poll_at <= ^now) and
            (is_nil(rule.lease_token) or is_nil(rule.lease_until) or rule.lease_until <= ^now),
        order_by: [asc_nulls_first: rule.next_poll_at, asc: rule.inserted_at, asc: rule.id],
        limit: ^limit,
        select: rule.id
      )
    )
  end

  defp start_scan_task(state, rule_id) do
    task = supervised_task(fn -> run_safely(fn -> run_poller(state.poller, rule_id, state.run_opts) end) end)
    put_in(state, [:running, task.ref], %{rule_id: rule_id, pid: task.pid})
  end

  defp supervised_task(fun), do: Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fun)

  defp run_poller(poller, rule_id, opts) when is_function(poller, 2), do: poller.(rule_id, opts)
  defp run_poller(poller, rule_id, _opts) when is_function(poller, 1), do: poller.(rule_id)
  defp run_poller(poller, rule_id, opts), do: poller.run(rule_id, opts)

  defp resume_safely(poller, context, opts), do: run_safely(fn -> poller.resume(context, opts) end)

  defp run_safely(fun) do
    fun.()
  rescue
    _error -> {:error, :scan_failed}
  catch
    _kind, _reason -> {:error, :scan_failed}
  end

  defp report_scan_result(_rule_id, {:ok, _scan}), do: nil
  defp report_scan_result(_rule_id, :ok), do: nil

  defp report_scan_result(rule_id, {:error, reason}) do
    error_code = safe_error_code(reason)
    Logger.warning("Jira intake scan failed rule_id=#{rule_id} error_code=#{error_code}")
    error_code
  end

  defp report_scan_result(rule_id, _result) do
    Logger.warning("Jira intake scan returned an invalid result rule_id=#{rule_id} error_code=invalid_result")
    "invalid_result"
  end

  defp safe_error_code(%{kind: kind}) when is_atom(kind), do: safe_error_code(kind)
  defp safe_error_code({:error, reason}), do: safe_error_code(reason)
  defp safe_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error_code(reason) when is_binary(reason) and reason in @safe_error_codes, do: reason
  defp safe_error_code(_reason), do: "scan_failed"

  defp notify_result_observer(%{result_observer: observer}, rule_id, error_code)
       when is_function(observer, 2),
       do: observer.(rule_id, error_code)

  defp notify_result_observer(_state, _rule_id, _error_code), do: :ok

  defp running_rule_ids(state), do: Enum.map(state.running, fn {_ref, worker} -> worker.rule_id end)

  defp rule_running?(state, rule_id), do: rule_id in running_rule_ids(state)

  defp active?(%AutomationRule{enabled: true}), do: true
  defp active?(%AutomationRule{enabled: false, activation_status: "activating"}), do: true
  defp active?(%AutomationRule{}), do: false

  defp intake_enabled?(%{enabled?: enabled}) when is_function(enabled, 0), do: enabled.()
  defp intake_enabled?(%{enabled?: enabled}), do: enabled == true

  defp effects_enabled?(%{effects_enabled?: enabled}) when is_function(enabled, 0), do: enabled.()
  defp effects_enabled?(%{effects_enabled?: enabled}), do: enabled == true

  defp lease_active?(%AutomationRule{lease_token: token, lease_until: until}, now)
       when is_binary(token) and not is_nil(until),
       do: DateTime.compare(until, now) == :gt

  defp lease_active?(%AutomationRule{}, _now), do: false

  defp schedule_tick(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp schedule_tick(_interval_ms), do: :ok
end
