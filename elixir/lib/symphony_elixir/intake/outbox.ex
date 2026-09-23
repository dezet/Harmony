defmodule SymphonyElixir.Intake.Outbox do
  @moduledoc """
  Durable leasing and retry state for intake effects.

  Claims and state transitions are short PostgreSQL transactions. Callers perform
  network I/O only after `claim/1` returns and persist results with the lease token.
  """

  import Ecto.Query

  alias SymphonyElixir.Intake
  alias SymphonyElixir.Repo

  alias SymphonyElixir.Storage.{
    IntakeAnalysis,
    IntakeCase,
    IntakeEvent,
    IntegrationConnection,
    IntegrationDelivery,
    WorkRun
  }

  @retry_intervals [30, 120, 600, 1_800]
  @max_automatic_attempts 5
  @max_analysis_model_starts 2
  # Analysis.timeout_ms is capped at 900 seconds by Config.Schema.Analysis.
  @analysis_deadline_max_seconds 900
  @analysis_recovery_grace_seconds 60
  @analysis_max_seconds @analysis_deadline_max_seconds + @analysis_recovery_grace_seconds
  @default_io_limit 4
  @default_analysis_limit 1
  @default_rate_limits %{email: 60, sms: 20}
  @seconds_per_hour 3_600
  @io_advisory_lock 1_994_092_201
  @analysis_advisory_lock 1_994_092_202
  @max_candidate_scan 100

  @type delivery_result :: {:ok, IntegrationDelivery.t()} | {:error, term()}

  @spec claim(keyword()) :: delivery_result() | :empty
  def claim(opts \\ []) do
    now = current_time(opts)
    switches = switches(opts)

    case Repo.transaction(fn -> claim_in_transaction(opts, now, switches) end) do
      {:ok, {result, _expired}} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_in_transaction(opts, now, switches) do
    expired = recover_expired_in_transaction(now)
    pause_disabled_connections(now)
    resume_enabled_connections(now)

    result = claim_if_enabled(opts, now, switches)
    {result, expired}
  end

  defp claim_if_enabled(opts, now, %{intake_enabled: true} = switches) do
    claim_candidate(opts, now, switches, [], 0)
  end

  defp claim_if_enabled(_opts, _now, _switches), do: :empty

  @spec heartbeat(binary(), String.t(), keyword()) :: delivery_result()
  def heartbeat(delivery_id, lease_token, opts \\ []) do
    now = current_time(opts)
    lease_until = DateTime.add(now, Keyword.get(opts, :lease_seconds, 120), :second)

    cas_update(delivery_id, lease_token, now, lease_until: lease_until)
  end

  @spec complete(binary(), String.t()) :: delivery_result()
  @spec complete(binary(), String.t(), map()) :: delivery_result()
  @spec complete(binary(), String.t(), map(), keyword()) :: delivery_result()
  def complete(delivery_id, lease_token, attrs \\ %{}, opts \\ []) do
    now = current_time(opts)

    Repo.transaction(fn ->
      with {:ok, delivery} <-
             update_leased(delivery_id, lease_token, now,
               status: "succeeded",
               provider_id: Map.get(attrs, :provider_id, Map.get(attrs, "provider_id")),
               sent_at: now,
               last_error_code: nil,
               lease_token: nil,
               lease_until: nil,
               updated_at: now,
               inc: [lock_version: 1]
             ) do
        record_event(delivery, "delivery_succeeded", %{provider_id: delivery.provider_id}, now)
        {:ok, delivery}
      end
    end)
    |> flatten_transaction_result()
  end

  @spec retry(binary(), String.t(), String.t()) :: delivery_result()
  @spec retry(binary(), String.t(), String.t(), String.t() | nil) :: delivery_result()
  @spec retry(binary(), String.t(), String.t(), String.t() | nil, keyword()) :: delivery_result()
  def retry(delivery_id, lease_token, error_code, retry_after \\ nil, opts \\ []) do
    now = current_time(opts)

    Repo.transaction(fn -> retry_in_transaction(delivery_id, lease_token, error_code, retry_after, now, opts) end)
    |> flatten_transaction_result()
  end

  defp retry_in_transaction(delivery_id, lease_token, error_code, retry_after, now, opts) do
    with {:ok, current} <- leased_delivery(delivery_id, lease_token, now) do
      persist_retry(current, delivery_id, lease_token, error_code, retry_after, now, opts)
    end
  end

  defp persist_retry(current, delivery_id, lease_token, error_code, retry_after, now, opts) do
    budget = retry_budget(current)

    {status, next_at} =
      if current.attempts < budget do
        {"retry_wait", next_attempt_at(now, current.attempts, retry_after, opts)}
      else
        {"failed", now}
      end

    event = retry_event(status)

    with {:ok, delivery} <-
           update_leased(delivery_id, lease_token, now,
             status: status,
             next_attempt_at: next_at,
             last_error_code: error_code,
             lease_token: nil,
             lease_until: nil,
             updated_at: now,
             inc: [lock_version: 1]
           ) do
      record_event(delivery, event, %{error_code: error_code, next_attempt_at: next_at}, now)
      {:ok, delivery}
    end
  end

  defp retry_event("failed"), do: "delivery_failed"
  defp retry_event(_status), do: "delivery_retry_scheduled"

  @spec fail(binary(), String.t(), String.t(), keyword()) :: delivery_result()
  def fail(delivery_id, lease_token, error_code, opts \\ []) do
    now = current_time(opts)

    Repo.transaction(fn ->
      with {:ok, delivery} <-
             update_leased(delivery_id, lease_token, now,
               status: "failed",
               last_error_code: error_code,
               lease_token: nil,
               lease_until: nil,
               updated_at: now,
               inc: [lock_version: 1]
             ) do
        record_event(delivery, "delivery_failed", %{error_code: error_code}, now)
        {:ok, delivery}
      end
    end)
    |> flatten_transaction_result()
  end

  @spec mark_unknown(binary(), String.t(), String.t(), keyword()) :: delivery_result()
  def mark_unknown(delivery_id, lease_token, error_code, opts \\ []) do
    now = current_time(opts)

    Repo.transaction(fn ->
      with {:ok, delivery} <-
             update_leased(delivery_id, lease_token, now,
               status: "unknown",
               last_error_code: error_code,
               lease_token: nil,
               lease_until: nil,
               updated_at: now,
               inc: [lock_version: 1]
             ) do
        record_event(delivery, "delivery_unknown", %{error_code: error_code}, now)
        {:ok, delivery}
      end
    end)
    |> flatten_transaction_result()
  end

  @spec recover_expired(DateTime.t(), keyword()) ::
          %{unknown: non_neg_integer(), analyses: non_neg_integer()} | {:error, term()}
  def recover_expired(now \\ current_time([]), opts \\ []) do
    case Repo.transaction(fn -> recover_expired_in_transaction(now, opts) end) do
      {:ok, counts} -> counts
      {:error, reason} -> {:error, reason}
    end
  end

  @spec recover_expired_analyses(DateTime.t(), keyword()) :: non_neg_integer() | {:error, term()}
  def recover_expired_analyses(now, opts \\ []) do
    case Repo.transaction(fn -> recover_expired_analysis_rows(now, opts) end) do
      {:ok, count} -> count
      {:error, reason} -> {:error, reason}
    end
  end

  @spec manual_retry(binary(), keyword()) :: delivery_result()
  def manual_retry(delivery_id, opts \\ []) do
    now = current_time(opts)

    with %IntegrationDelivery{} = initial <- Repo.get(IntegrationDelivery, delivery_id),
         :ok <- check_manual_retry(initial, opts),
         :ok <- reconcile_unknown(initial, opts) do
      Repo.transaction(fn -> manual_retry_in_transaction(delivery_id, now) end)
      |> flatten_transaction_result()
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp manual_retry_in_transaction(delivery_id, now) do
    case Repo.one(from(d in IntegrationDelivery, where: d.id == ^delivery_id, lock: "FOR UPDATE")) do
      %IntegrationDelivery{} = delivery -> retry_manually(delivery, now)
      nil -> {:error, :not_found}
    end
  end

  defp retry_manually(delivery, now) do
    with :ok <- check_retryable_status(delivery),
         :ok <- ensure_connection_enabled(delivery) do
      payload = Map.put(delivery.payload, "manual_retries", manual_retries(delivery.payload) + 1)

      changes = %{
        status: "retry_wait",
        next_attempt_at: now,
        payload: payload,
        lease_token: nil,
        lease_until: nil,
        lock_version: delivery.lock_version + 1
      }

      updated = delivery |> IntegrationDelivery.changeset(changes) |> Repo.update!()
      record_event(updated, "delivery_manual_retry", %{attempts: updated.attempts}, now, "operator")
      {:ok, updated}
    end
  end

  @spec next_attempt_at(DateTime.t(), pos_integer(), String.t() | nil, keyword()) :: DateTime.t()
  def next_attempt_at(now, attempt, retry_after, opts \\ []) do
    base = Enum.at(@retry_intervals, attempt - 1, List.last(@retry_intervals))
    jitter = jitter_seconds(base, Keyword.get(opts, :jitter, &:rand.uniform/0))
    scheduled = DateTime.add(now, base + jitter, :second)

    case parse_retry_after(retry_after, now) do
      %DateTime{} = retry_at -> max_datetime(scheduled, retry_at)
      nil -> scheduled
    end
  end

  defp claim_candidate(_opts, _now, _switches, _excluded, attempts) when attempts >= @max_candidate_scan,
    do: :empty

  @spec claim_candidate(keyword(), DateTime.t(), map(), [binary()], non_neg_integer()) ::
          delivery_result() | :empty
  defp claim_candidate(opts, now, switches, excluded, attempts) do
    case next_candidate(opts, now, switches, excluded) do
      nil ->
        :empty

      delivery ->
        claim_selected_candidate(delivery, opts, now, switches, excluded, attempts)
    end
  end

  @spec claim_selected_candidate(
          IntegrationDelivery.t(),
          keyword(),
          DateTime.t(),
          map(),
          [binary()],
          non_neg_integer()
        ) :: delivery_result() | :empty
  defp claim_selected_candidate(delivery, opts, now, switches, excluded, attempts) do
    category = category(delivery.operation)
    advisory_lock!(category)

    if active_claim_count(category, now) >= category_limit(category, opts) do
      skip_candidate(delivery, opts, now, switches, excluded, attempts)
    else
      rate_limit_or_lease(delivery, opts, now, switches, excluded, attempts)
    end
  end

  @spec rate_limit_or_lease(
          IntegrationDelivery.t(),
          keyword(),
          DateTime.t(),
          map(),
          [binary()],
          non_neg_integer()
        ) :: delivery_result() | :empty
  defp rate_limit_or_lease(delivery, opts, now, switches, excluded, attempts) do
    case rate_limit_delivery(delivery, now, opts) do
      :allowed -> lease_delivery(delivery, now, opts)
      {:delayed, _updated} -> skip_candidate(delivery, opts, now, switches, excluded, attempts)
    end
  end

  @spec skip_candidate(
          IntegrationDelivery.t(),
          keyword(),
          DateTime.t(),
          map(),
          [binary()],
          non_neg_integer()
        ) :: delivery_result() | :empty
  defp skip_candidate(delivery, opts, now, switches, excluded, attempts) do
    claim_candidate(opts, now, switches, [delivery.id | excluded], attempts + 1)
  end

  @spec next_candidate(keyword(), DateTime.t(), map(), [binary()]) ::
          IntegrationDelivery.t() | nil
  defp next_candidate(opts, now, switches, excluded) do
    query =
      from(d in IntegrationDelivery,
        where: d.status in ["pending", "retry_wait"],
        where: d.next_attempt_at <= ^now,
        order_by: [asc: d.next_attempt_at, asc: d.inserted_at, asc: d.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    query = maybe_filter_operation(query, Keyword.get(opts, :operation))
    query = maybe_filter_connection(query, Keyword.get(opts, :connection_id))
    query = require_linear_confirmation(query)
    query = filter_switches(query, switches)
    query = exclude_delivery_ids(query, excluded)
    Repo.one(query)
  end

  defp require_linear_confirmation(query) do
    where(
      query,
      [d],
      d.operation != "analysis" or
        fragment(
          "EXISTS (SELECT 1 FROM intake_cases AS intake_case WHERE intake_case.id = ? AND intake_case.linear_confirmed_at IS NOT NULL)",
          d.case_id
        )
    )
  end

  defp maybe_filter_operation(query, nil), do: query

  defp maybe_filter_operation(query, operation) do
    operation = to_string(operation)
    where(query, [d], d.operation == ^operation)
  end

  defp maybe_filter_connection(query, nil), do: query

  defp maybe_filter_connection(query, connection_id) do
    where(query, [d], d.connection_id == ^connection_id)
  end

  defp filter_switches(query, %{effects_enabled: true, analysis_enabled: true}), do: query

  defp filter_switches(query, %{effects_enabled: true, analysis_enabled: false}) do
    where(query, [d], d.operation != "analysis")
  end

  defp filter_switches(query, %{effects_enabled: false, analysis_enabled: true}) do
    where(query, [d], d.operation == "analysis")
  end

  defp filter_switches(query, _switches), do: where(query, [d], false)

  @spec exclude_delivery_ids(Ecto.Query.t(), [binary()]) :: Ecto.Query.t()
  defp exclude_delivery_ids(query, excluded) do
    if excluded == [] do
      query
    else
      where(query, [d], d.id not in ^excluded)
    end
  end

  defp lease_delivery(delivery, now, opts) do
    token = Ecto.UUID.generate()
    lease_until = DateTime.add(now, Keyword.get(opts, :lease_seconds, 120), :second)

    changes = %{
      status: "running",
      attempts: delivery.attempts + 1,
      first_attempt_at: delivery.first_attempt_at || now,
      lease_token: token,
      lease_until: lease_until,
      lock_version: delivery.lock_version + 1
    }

    updated = delivery |> IntegrationDelivery.changeset(changes) |> Repo.update!()

    if updated.operation == "analysis" do
      start_analysis_attempt(updated, now)
    end

    record_delivery_attempt(updated, now)
    record_event(updated, "delivery_claimed", %{attempt: updated.attempts}, now)
    {:ok, updated}
  end

  defp rate_limit_delivery(%IntegrationDelivery{operation: operation, connection_id: connection_id} = delivery, now, opts)
       when operation in ["email", "sms"] and not is_nil(connection_id) do
    limit = rate_limit(operation, opts)

    _connection =
      Repo.one(from(c in IntegrationConnection, where: c.id == ^connection_id, lock: "FOR UPDATE"))

    window_start = DateTime.add(now, -@seconds_per_hour, :second)

    recent_count =
      Repo.aggregate(
        from(e in IntakeEvent,
          where: e.type == "delivery_attempt",
          where: e.payload["connection_id"] == ^connection_id,
          where: e.payload["operation"] == ^operation,
          where: e.occurred_at >= ^window_start
        ),
        :count,
        :id
      )

    if recent_count < limit do
      :allowed
    else
      first_attempt = oldest_recent_attempt(connection_id, operation, window_start)
      next_at = DateTime.add(first_attempt || now, @seconds_per_hour, :second)

      updated =
        delivery
        |> IntegrationDelivery.changeset(%{
          status: "retry_wait",
          next_attempt_at: next_at,
          last_error_code: "rate_limited",
          lock_version: delivery.lock_version + 1
        })
        |> Repo.update!()

      record_event(updated, "delivery_rate_limited", %{next_attempt_at: next_at}, now)
      {:delayed, updated}
    end
  end

  defp rate_limit_delivery(%IntegrationDelivery{operation: operation, connection_id: nil} = delivery, now, _opts)
       when operation in ["email", "sms", "jira_comment"] do
    updated =
      delivery
      |> IntegrationDelivery.changeset(%{
        status: "failed",
        last_error_code: "connection_required",
        lock_version: delivery.lock_version + 1
      })
      |> Repo.update!()

    record_event(updated, "delivery_failed", %{error_code: "connection_required"}, now)
    {:delayed, updated}
  end

  defp rate_limit_delivery(_delivery, _now, _opts), do: :allowed

  defp oldest_recent_attempt(connection_id, operation, window_start) do
    Repo.one(
      from(e in IntakeEvent,
        where: e.type == "delivery_attempt",
        where: e.payload["connection_id"] == ^connection_id,
        where: e.payload["operation"] == ^operation,
        where: e.occurred_at >= ^window_start,
        select: min(e.occurred_at)
      )
    )
  end

  defp record_delivery_attempt(%IntegrationDelivery{operation: operation, connection_id: connection_id} = delivery, now)
       when operation in ["email", "sms"] and not is_nil(connection_id) do
    record_event(delivery, "delivery_attempt", %{connection_id: connection_id, operation: operation}, now)
  end

  defp record_delivery_attempt(_delivery, _now), do: :ok

  defp category("analysis"), do: :analysis
  defp category(_operation), do: :io

  defp category_limit(:analysis, opts), do: Keyword.get(opts, :analysis_limit, @default_analysis_limit)
  defp category_limit(:io, opts), do: Keyword.get(opts, :io_limit, @default_io_limit)

  defp advisory_lock!(:analysis), do: Repo.query!("SELECT pg_advisory_xact_lock($1)", [@analysis_advisory_lock])
  defp advisory_lock!(:io), do: Repo.query!("SELECT pg_advisory_xact_lock($1)", [@io_advisory_lock])

  defp active_claim_count(:analysis, now) do
    Repo.aggregate(
      from(d in IntegrationDelivery,
        where: d.status == "running" and d.operation == "analysis" and d.lease_until > ^now
      ),
      :count,
      :id
    )
  end

  defp active_claim_count(:io, now) do
    Repo.aggregate(
      from(d in IntegrationDelivery,
        where: d.status == "running" and d.operation != "analysis" and d.lease_until > ^now
      ),
      :count,
      :id
    )
  end

  defp pause_disabled_connections(now) do
    disabled_ids = Repo.all(from(c in IntegrationConnection, where: c.enabled == false, select: c.id))

    if disabled_ids != [] do
      deliveries =
        Repo.all(
          from(d in IntegrationDelivery,
            where: d.connection_id in ^disabled_ids,
            where: d.status in ["pending", "retry_wait"],
            order_by: [asc: d.id],
            lock: "FOR UPDATE SKIP LOCKED"
          )
        )

      Enum.each(deliveries, fn delivery ->
        payload = Map.put(delivery.payload, "resume_status", delivery.status)

        updated =
          delivery
          |> IntegrationDelivery.changeset(%{
            status: "paused",
            payload: payload,
            lock_version: delivery.lock_version + 1
          })
          |> Repo.update!()

        record_event(updated, "delivery_paused", %{resume_status: delivery.status}, now)
      end)
    end
  end

  defp resume_enabled_connections(now) do
    enabled_ids = Repo.all(from(c in IntegrationConnection, where: c.enabled == true, select: c.id))

    if enabled_ids != [] do
      deliveries =
        Repo.all(
          from(d in IntegrationDelivery,
            where: d.connection_id in ^enabled_ids and d.status == "paused",
            order_by: [asc: d.id],
            lock: "FOR UPDATE SKIP LOCKED"
          )
        )

      Enum.each(deliveries, &resume_delivery(&1, now))
    end
  end

  defp resume_delivery(delivery, now) do
    status = resumed_status(delivery.payload)

    updated =
      delivery
      |> IntegrationDelivery.changeset(%{
        status: status,
        payload: Map.drop(delivery.payload, ["resume_status", :resume_status]),
        lock_version: delivery.lock_version + 1
      })
      |> Repo.update!()

    record_event(updated, "delivery_resumed", %{status: status}, now)
  end

  defp resumed_status(payload) do
    case Map.get(payload, "resume_status", "pending") do
      status when status in ~w(pending retry_wait unknown failed succeeded) -> status
      _status -> "pending"
    end
  end

  defp recover_expired_in_transaction(now, opts \\ []) do
    unknown = recover_expired_writes(now)
    analyses = recover_expired_analysis_rows(now, opts)
    %{unknown: unknown, analyses: analyses}
  end

  defp recover_expired_writes(now) do
    expired =
      Repo.all(
        from(d in IntegrationDelivery,
          where: d.status == "running" and d.operation != "analysis" and d.lease_until <= ^now,
          order_by: [asc: d.id],
          lock: "FOR UPDATE SKIP LOCKED"
        )
      )

    Enum.each(expired, fn delivery ->
      updated =
        delivery
        |> IntegrationDelivery.changeset(%{
          status: "unknown",
          last_error_code: "lease_expired",
          lease_token: nil,
          lease_until: nil,
          lock_version: delivery.lock_version + 1
        })
        |> Repo.update!()

      record_event(updated, "delivery_unknown", %{error_code: "lease_expired"}, now)
    end)

    length(expired)
  end

  defp recover_expired_analysis_rows(now, _opts) do
    running =
      Repo.all(
        from(d in IntegrationDelivery,
          where: d.status == "running" and d.operation == "analysis",
          order_by: [asc: d.id],
          lock: "FOR UPDATE SKIP LOCKED"
        )
      )

    expired = Enum.filter(running, &analysis_expired?(&1, now))

    Enum.each(expired, fn delivery ->
      version = payload_version(delivery.payload)

      if delivery.case_id do
        analysis = Repo.get_by(IntakeAnalysis, case_id: delivery.case_id, version: version)

        Repo.update_all(
          from(a in IntakeAnalysis,
            where: a.case_id == ^delivery.case_id and a.version == ^version and a.status == "running"
          ),
          set: [status: "queued", started_at: nil, error_code: "lease_expired", updated_at: now]
        )

        Repo.update_all(
          from(c in IntakeCase, where: c.id == ^delivery.case_id and c.analysis_version == ^version),
          set: [analysis_status: "queued", updated_at: now],
          inc: [lock_version: 1]
        )

        mark_expired_analysis_work_run(analysis, now)
      end

      updated =
        delivery
        |> IntegrationDelivery.changeset(%{
          status: "pending",
          next_attempt_at: now,
          last_error_code: "analysis_lease_expired",
          lease_token: nil,
          lease_until: nil,
          lock_version: delivery.lock_version + 1
        })
        |> Repo.update!()

      record_event(updated, "analysis_recovered", %{version: version}, now)
    end)

    length(expired)
  end

  defp update_leased(delivery_id, lease_token, now, updates) do
    {increments, changes} = Keyword.pop(updates, :inc, [])
    query = leased_query(delivery_id, lease_token, now)

    case Repo.update_all(query, set: changes, inc: increments) do
      {1, _rows} -> {:ok, Repo.get!(IntegrationDelivery, delivery_id)}
      {0, _rows} -> {:error, :stale_lease}
    end
  end

  defp cas_update(delivery_id, lease_token, now, updates) do
    case update_leased(delivery_id, lease_token, now, Keyword.merge(updates, inc: [lock_version: 1])) do
      {:ok, delivery} -> {:ok, delivery}
      error -> error
    end
  end

  defp leased_delivery(delivery_id, lease_token, now) do
    case Repo.one(leased_query(delivery_id, lease_token, now)) do
      %IntegrationDelivery{} = delivery -> {:ok, delivery}
      nil -> {:error, :stale_lease}
    end
  end

  defp leased_query(delivery_id, lease_token, now) do
    query =
      from(d in IntegrationDelivery,
        as: :delivery,
        where:
          d.id == ^delivery_id and d.status == "running" and d.lease_token == ^lease_token and
            d.lease_until > ^now
      )

    analysis_deadline = DateTime.add(now, -@analysis_max_seconds, :second)

    where(
      query,
      [delivery: d],
      d.operation != "analysis" or is_nil(d.case_id) or
        fragment(
          "EXISTS (SELECT 1 FROM intake_analyses AS a WHERE a.case_id = ? AND a.version = CASE WHEN (?->>'version') ~ '^[0-9]+$' THEN ((?->>'version')::integer) ELSE 1 END AND a.started_at > ?)",
          d.case_id,
          d.payload,
          d.payload,
          ^analysis_deadline
        )
    )
  end

  defp start_analysis_attempt(%IntegrationDelivery{case_id: nil}, _now), do: :ok

  defp start_analysis_attempt(%IntegrationDelivery{} = delivery, now) do
    version = payload_version(delivery.payload)

    Repo.update_all(
      from(a in IntakeAnalysis,
        where:
          a.case_id == ^delivery.case_id and a.version == ^version and
            a.status in ["queued", "running", "failed"]
      ),
      set: [status: "running", started_at: now, completed_at: nil, error_code: nil, updated_at: now]
    )

    Repo.update_all(
      from(c in IntakeCase, where: c.id == ^delivery.case_id and c.analysis_version == ^version),
      set: [analysis_status: "running", updated_at: now],
      inc: [lock_version: 1]
    )

    record_event(delivery, "analysis_started", %{version: version}, now)
  end

  defp retry_budget(%IntegrationDelivery{operation: "analysis"}), do: @max_analysis_model_starts

  defp retry_budget(%IntegrationDelivery{payload: payload}) do
    @max_automatic_attempts + manual_retries(payload)
  end

  defp mark_expired_analysis_work_run(%IntakeAnalysis{work_run_id: work_run_id}, _now)
       when is_binary(work_run_id) do
    case Repo.get(WorkRun, work_run_id) do
      %WorkRun{status: "running"} = work_run ->
        payload = Map.put(work_run.payload || %{}, "error_code", "analysis_lease_expired")

        work_run
        |> WorkRun.changeset(%{status: "failed", payload: payload})
        |> Repo.update!()

      _other ->
        :ok
    end
  end

  defp mark_expired_analysis_work_run(_analysis, _now), do: :ok

  defp analysis_expired?(%IntegrationDelivery{lease_until: lease_until} = delivery, now) do
    lease_expired? = is_nil(lease_until) or DateTime.compare(lease_until, now) != :gt

    if lease_expired? do
      true
    else
      analysis_deadline_expired?(delivery, now)
    end
  end

  defp analysis_deadline_expired?(%IntegrationDelivery{case_id: nil}, _now), do: false

  defp analysis_deadline_expired?(%IntegrationDelivery{} = delivery, now) do
    cutoff = DateTime.add(now, -@analysis_max_seconds, :second)
    version = payload_version(delivery.payload)

    case Repo.one(
           from(a in IntakeAnalysis,
             where: a.case_id == ^delivery.case_id and a.version == ^version,
             select: a.started_at
           )
         ) do
      %DateTime{} = started_at -> DateTime.compare(started_at, cutoff) != :gt
      _missing -> true
    end
  end

  defp check_manual_retry(%IntegrationDelivery{operation: "analysis"}, _opts),
    do: {:error, :analysis_retry_requires_new_version}

  defp check_manual_retry(%IntegrationDelivery{status: "unknown"}, opts) do
    if Keyword.get(opts, :confirm_duplicate_risk, false), do: :ok, else: {:error, :confirmation_required}
  end

  defp check_manual_retry(%IntegrationDelivery{status: status}, _opts) when status in ["failed", "unknown"], do: :ok
  defp check_manual_retry(%IntegrationDelivery{status: "paused"}, _opts), do: {:error, :dependency_paused}
  defp check_manual_retry(%IntegrationDelivery{}, _opts), do: {:error, :not_retryable}

  defp check_retryable_status(%IntegrationDelivery{status: status}) when status in ["failed", "unknown"], do: :ok
  defp check_retryable_status(%IntegrationDelivery{status: "paused"}), do: {:error, :dependency_paused}
  defp check_retryable_status(%IntegrationDelivery{}), do: {:error, :not_retryable}

  defp reconcile_unknown(%IntegrationDelivery{status: "unknown"} = delivery, opts) do
    case Keyword.get(opts, :reconcile) do
      nil when delivery.operation in ["linear_create", "jira_comment"] -> {:error, :reconciliation_required}
      nil -> :ok
      fun when is_function(fun, 1) -> reconcile_result(fun.(delivery))
      module when is_atom(module) -> reconcile_result(module.reconcile(delivery))
      _ -> {:error, :reconciliation_required}
    end
  end

  defp reconcile_unknown(_delivery, _opts), do: :ok

  defp reconcile_result(:safe_to_retry), do: :ok
  defp reconcile_result(:already_applied), do: {:error, :effect_already_applied}
  defp reconcile_result(_result), do: {:error, :reconciliation_failed}

  defp ensure_connection_enabled(%IntegrationDelivery{connection_id: nil}), do: :ok

  defp ensure_connection_enabled(%IntegrationDelivery{connection_id: connection_id}) do
    case Repo.get(IntegrationConnection, connection_id) do
      %IntegrationConnection{enabled: true} -> :ok
      _connection -> {:error, :dependency_paused}
    end
  end

  defp flatten_transaction_result({:ok, {:ok, delivery}}), do: {:ok, delivery}
  defp flatten_transaction_result({:ok, {:error, reason}}), do: {:error, reason}
  defp flatten_transaction_result({:error, reason}), do: {:error, reason}

  defp record_event(%IntegrationDelivery{case_id: case_id, id: delivery_id}, type, payload, now, actor \\ "system") do
    %IntakeEvent{}
    |> IntakeEvent.changeset(%{
      case_id: case_id,
      type: type,
      payload: stringify_payload(Map.put(payload, :delivery_id, delivery_id)),
      actor: actor,
      occurred_at: now
    })
    |> Repo.insert!()
  end

  defp stringify_payload(payload) do
    Map.new(payload, fn {key, value} -> {to_string(key), value} end)
  end

  defp payload_version(payload) do
    Map.get(payload, "version") || Map.get(payload, :version) || 1
  end

  defp manual_retries(payload) do
    Map.get(payload, "manual_retries") || Map.get(payload, :manual_retries) || 0
  end

  defp rate_limit(operation, opts) do
    limits = Keyword.get(opts, :rate_limits, @default_rate_limits)
    Map.get(limits, String.to_existing_atom(operation), Map.get(limits, operation, Map.fetch!(@default_rate_limits, String.to_existing_atom(operation))))
  end

  defp switches(opts) do
    defaults = Intake.runtime_settings()

    %{
      intake_enabled: Keyword.get(opts, :intake_enabled, defaults.intake.enabled),
      effects_enabled: Keyword.get(opts, :effects_enabled, defaults.intake.effects_enabled),
      analysis_enabled: Keyword.get(opts, :analysis_enabled, defaults.analysis.enabled)
    }
  end

  defp current_time(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _ -> Keyword.get(opts, :now, DateTime.utc_now())
    end
    |> DateTime.truncate(:microsecond)
  end

  defp jitter_seconds(base, jitter_fun) when is_function(jitter_fun, 0) do
    ratio = jitter_fun.() |> max(0.0) |> min(1.0)
    max(1, round(base * 0.1 * ratio))
  end

  defp jitter_seconds(base, _jitter_fun), do: max(1, round(base * 0.1 * :rand.uniform()))

  defp parse_retry_after(nil, _now), do: nil

  defp parse_retry_after(value, now) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> DateTime.add(now, seconds, :second)
      _ -> parse_http_date(value, now)
    end
  end

  defp parse_retry_after(_value, _now), do: nil

  defp parse_http_date(value, now) do
    case String.split(value) do
      [weekday, day, month, year, time, "GMT"] ->
        with true <- weekday_token?(weekday, :short),
             {year, ""} <- Integer.parse(year),
             {day, ""} <- Integer.parse(day) do
          build_http_datetime(year, month, day, time)
        else
          _invalid -> nil
        end

      [weekday, date, time, "GMT"] ->
        with true <- weekday_token?(weekday, :long),
             [day, month, year] <- String.split(date, "-"),
             {day, ""} <- Integer.parse(day),
             {short_year, ""} <- Integer.parse(year) do
          year = rfc850_year(short_year, now.year)
          build_http_datetime(year, month, day, time)
        else
          _invalid -> nil
        end

      [weekday, month, day, time, year] ->
        with true <- weekday_token?(weekday, :short),
             {day, ""} <- Integer.parse(day),
             {year, ""} <- Integer.parse(year) do
          build_http_datetime(year, month, day, time)
        else
          _invalid -> nil
        end

      _invalid ->
        nil
    end
  end

  defp weekday_token?(weekday, :short), do: String.trim_trailing(weekday, ",") in ~w(Mon Tue Wed Thu Fri Sat Sun)

  defp weekday_token?(weekday, :long) do
    String.trim_trailing(weekday, ",") in ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  end

  defp rfc850_year(short_year, current_year) do
    year = div(current_year, 100) * 100 + short_year
    if year > current_year + 50, do: year - 100, else: year
  end

  defp build_http_datetime(year, month, day, time) do
    with {:ok, month} <- month_number(month),
         {:ok, date} <- Date.new(year, month, day),
         [_, hour, minute, second] <- Regex.run(~r/\A(\d{2}):(\d{2}):(\d{2})\z/, time),
         {hour, ""} <- Integer.parse(hour),
         {minute, ""} <- Integer.parse(minute),
         {second, ""} <- Integer.parse(second),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, naive_datetime} <- NaiveDateTime.new(date, time),
         {:ok, datetime} <- DateTime.from_naive(naive_datetime, "Etc/UTC") do
      datetime
    else
      _invalid -> nil
    end
  end

  defp month_number("Jan"), do: {:ok, 1}
  defp month_number("Feb"), do: {:ok, 2}
  defp month_number("Mar"), do: {:ok, 3}
  defp month_number("Apr"), do: {:ok, 4}
  defp month_number("May"), do: {:ok, 5}
  defp month_number("Jun"), do: {:ok, 6}
  defp month_number("Jul"), do: {:ok, 7}
  defp month_number("Aug"), do: {:ok, 8}
  defp month_number("Sep"), do: {:ok, 9}
  defp month_number("Oct"), do: {:ok, 10}
  defp month_number("Nov"), do: {:ok, 11}
  defp month_number("Dec"), do: {:ok, 12}
  defp month_number(_month), do: :error

  defp max_datetime(left, right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end
end
