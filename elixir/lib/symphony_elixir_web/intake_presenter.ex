defmodule SymphonyElixirWeb.IntakePresenter do
  @moduledoc """
  JSON projections and the error envelope of the intake API: configuration,
  deliveries and the Case Center reads.

  Responses never carry secrets, raw provider bodies or exception text.
  Every error is `{"error": {"code", "message", "fields"}}` with a stable code
  that the UI translates.
  """

  import Plug.Conn, only: [put_status: 2]

  alias Phoenix.Controller
  alias SymphonyElixir.Intake.Connections
  alias SymphonyElixir.Storage.{AutomationRule, IntakeCase, IntegrationConnection, IntegrationDelivery}

  @default_page_size 25
  @max_page_size 100

  @errors %{
    method_not_allowed: {405, "Method not allowed"},
    not_found: {404, "Resource not found"},
    invalid_cursor: {400, "Cursor is invalid for this query"},
    invalid_page_size: {400, "page_size must be an integer between 1 and 100"},
    invalid_query: {400, "Query parameter is invalid"},
    validation_failed: {422, "Validation failed"},
    confirmation_required: {422, "Explicit confirmation is required"},
    invalid_idempotency_key: {422, "Idempotency-Key must be a UUID"},
    immutable_after_activation: {422, "Field cannot change after the first activation"},
    unsupported_case_kind: {422, "Action is available only for Jira cases"},
    test_send_unsupported: {422, "Test-send is available only for SMTP and SMSAPI connections"},
    connection_kind_mismatch: {422, "Connection has a different kind"},
    scan_limit_exceeded: {422, "Source returns too many issues; narrow the filter"},
    invalid_action: {422, "Action arguments are invalid"},
    stale_version: {409, "Resource was changed by someone else; reload it"},
    status_mismatch: {409, "Delivery status changed; reload it"},
    effects_disabled: {409, "External effects are disabled by intake.effects_enabled"},
    intake_disabled: {409, "Intake is disabled by intake.enabled"},
    source_conflict: {409, "Another active rule already watches this source"},
    scan_in_progress: {409, "A scan of this rule is already running"},
    scan_capacity: {409, "Scan capacity is exhausted; try again later"},
    rule_not_active: {409, "Rule is not active"},
    analysis_not_ready: {409, "Analysis is not ready"},
    analysis_not_published: {409, "Analysis comment is not published yet"},
    linear_not_confirmed: {409, "Linear issue is not confirmed yet"},
    repair_already_approved: {409, "Repair is already approved"},
    not_retryable: {409, "Delivery cannot be retried in its current state"},
    dependency_paused: {409, "Delivery connection is disabled"},
    analysis_retry_requires_new_version: {409, "Analysis is retried by requesting a new version"},
    effect_already_applied: {409, "Provider already applied this effect"},
    reconciliation_required: {409, "Delivery needs manual reconciliation before a retry"},
    idempotency_key_conflict: {409, "Idempotency-Key was already used for a different request"},
    connection_disabled: {409, "Connection is disabled"},
    jira_connection_disabled: {409, "Jira connection is disabled"},
    credentials_missing: {409, "Connection credentials are not set"},
    analysis_profile_unavailable: {503, "Analysis profile is not configured"},
    scheduler_unavailable: {503, "Intake scheduler is not running"},
    reconciliation_failed: {503, "Provider state could not be read"},
    action_unavailable: {503, "Action is temporarily unavailable"}
  }

  @dependency_codes ~w(
    jira_auth_failed jira_source_not_found jira_rate_limited jira_unavailable jira_invalid_configuration
    linear_auth_failed linear_unavailable linear_label_create_failed missing_linear_api_token
  )

  @type error_reason ::
          atom()
          | {:validation, map()}
          | {:dependency, String.t()}
          | {:confirmation_required, String.t()}
          | {:activation_blocked, String.t(), map()}
          | Ecto.Changeset.t()

  @spec rule(AutomationRule.t()) :: map()
  def rule(%AutomationRule{} = rule) do
    Map.take(rule, [
      :id,
      :project_id,
      :jira_connection_id,
      :name,
      :source_type,
      :source_id,
      :priority_ids,
      :interval_seconds,
      :initial_policy,
      :linear_team_id,
      :linear_project_id,
      :linear_todo_state_id,
      :linear_hold_label_id,
      :email_connection_id,
      :sms_connection_id,
      :email_recipients,
      :sms_recipients,
      :enabled,
      :config_version,
      :activation_status,
      :activated_at,
      :baseline_complete_at,
      :baseline_generation,
      :last_started_at,
      :last_success_at,
      :next_poll_at,
      :last_error_code,
      :lease_until,
      :lock_version
    ])
  end

  @spec connection(IntegrationConnection.t()) :: map()
  def connection(%IntegrationConnection{} = connection) do
    presented = Connections.present(connection)

    %{
      id: presented.id,
      kind: presented.kind,
      name: presented.name,
      settings: presented.settings,
      secret_state: presented.secret_status,
      secret_version: connection.secret_version,
      enabled: presented.enabled,
      last_checked_at: presented.last_checked_at,
      health: presented.health,
      error_code: presented.error_code,
      lock_version: presented.lock_version
    }
  end

  @doc "Delivery projection without payload, recipients or provider bodies."
  @spec delivery(IntegrationDelivery.t()) :: map()
  def delivery(%IntegrationDelivery{} = delivery) do
    %{
      id: delivery.id,
      operation: delivery.operation,
      status: delivery.status,
      attempts: delivery.attempts,
      next_attempt_at: delivery.next_attempt_at,
      provider_id: delivery.provider_id,
      first_attempt_at: delivery.first_attempt_at,
      sent_at: delivery.sent_at,
      last_error_code: delivery.last_error_code,
      retry_allowed: retry_allowed?(delivery),
      duplicate_risk: delivery.status == "unknown"
    }
  end

  @doc "Operator decision state of a Jira case after an action."
  @spec case_state(IntakeCase.t()) :: map()
  def case_state(%IntakeCase{} = intake_case) do
    %{
      ref: "jira_" <> intake_case.id,
      jira_key: intake_case.jira_key,
      analysis_version: intake_case.analysis_version,
      analysis_status: intake_case.analysis_status,
      acknowledged_at: intake_case.acknowledged_at,
      repair_approved_at: intake_case.repair_approved_at,
      repair_approved_version: intake_case.repair_approved_version,
      version: intake_case.lock_version
    }
  end

  @doc """
  Parses `page_size` and `cursor`. A cursor is bound to the query it came
  from through `scope`; a cursor of another query is rejected.
  """
  @spec page_params(map(), String.t(), pos_integer()) ::
          {:ok, %{page_size: pos_integer(), after: term()}} | {:error, :invalid_cursor | :invalid_page_size}
  def page_params(params, scope, default_page_size \\ @default_page_size) do
    with {:ok, page_size} <- page_size(Map.get(params, "page_size"), default_page_size),
         {:ok, position} <- decode_cursor(Map.get(params, "cursor"), scope) do
      {:ok, %{page_size: page_size, after: position}}
    end
  end

  @doc """
  Turns a decoded `(timestamp, id)` cursor position into `{DateTime, id}`.
  `valid_id?` checks the second element (a case ref or a UUID).
  """
  @spec timestamp_after(term(), (String.t() -> boolean())) ::
          {:ok, nil | {DateTime.t(), String.t()}} | {:error, :invalid_cursor}
  def timestamp_after(nil, _valid_id?), do: {:ok, nil}

  def timestamp_after([timestamp, id], valid_id?) when is_binary(timestamp) and is_binary(id) do
    with {:ok, datetime, 0} <- DateTime.from_iso8601(timestamp),
         true <- valid_id?.(id) do
      {:ok, {datetime, id}}
    else
      _invalid -> {:error, :invalid_cursor}
    end
  end

  def timestamp_after(_position, _valid_id?), do: {:error, :invalid_cursor}

  @doc "`GET /cases` response: summaries, totals, per-column counts and project sums."
  @spec cases_page(map(), pos_integer(), String.t()) :: map()
  def cases_page(result, page_size, scope) do
    %{
      items: result.items,
      meta: %{
        next_cursor: result.next_position && encode_cursor(result.next_position, scope),
        total: result.total,
        page_size: page_size
      },
      counts: result.counts,
      project_counts: result.project_counts
    }
  end

  @doc "Case detail with deliveries presented without payload or recipients."
  @spec case_detail(map()) :: map()
  def case_detail(detail), do: Map.update!(detail, :deliveries, fn deliveries -> Enum.map(deliveries, &delivery/1) end)

  @doc "`GET /cases/:ref/events` response."
  @spec case_events_page(map(), pos_integer(), String.t()) :: map()
  def case_events_page(result, page_size, scope) do
    %{
      items: Enum.map(result.items, &case_event/1),
      meta: %{next_cursor: result.next_position && encode_cursor(result.next_position, scope), page_size: page_size}
    }
  end

  @doc "One history entry; `Cases.events/2` has already masked recipients."
  @spec case_event(map()) :: map()
  def case_event(event), do: Map.take(event, [:id, :type, :actor, :occurred_at, :operation, :recipient, :payload])

  @doc "Turns a decoded keyset cursor position into `{inserted_at, id}`."
  @spec keyset_after(term()) :: {:ok, nil | {DateTime.t(), binary()}} | {:error, :invalid_cursor}
  def keyset_after(nil), do: {:ok, nil}

  def keyset_after([inserted_at, id]) when is_binary(inserted_at) do
    with {:ok, datetime, 0} <- DateTime.from_iso8601(inserted_at),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      {:ok, {datetime, uuid}}
    else
      _invalid -> {:error, :invalid_cursor}
    end
  end

  def keyset_after(_position), do: {:error, :invalid_cursor}

  @doc "Turns a decoded offset cursor position into a non-negative offset."
  @spec offset_after(term()) :: {:ok, non_neg_integer()} | {:error, :invalid_cursor}
  def offset_after(nil), do: {:ok, 0}
  def offset_after(offset) when is_integer(offset) and offset >= 0, do: {:ok, offset}
  def offset_after(_position), do: {:error, :invalid_cursor}

  @doc """
  Builds a keyset page from `page_size + 1` records ordered by
  `(inserted_at, id)`.
  """
  @spec page([struct()], pos_integer(), String.t(), (struct() -> map())) :: map()
  def page(records, page_size, scope, present_fun) do
    {visible, rest} = Enum.split(records, page_size)

    next_cursor =
      case {rest, List.last(visible)} do
        {[_ | _], %{inserted_at: inserted_at, id: id}} -> encode_cursor([DateTime.to_iso8601(inserted_at), id], scope)
        _no_more -> nil
      end

    %{items: Enum.map(visible, present_fun), meta: %{next_cursor: next_cursor, page_size: page_size}}
  end

  @doc "Builds an offset page over an already complete list."
  @spec offset_page([map()], non_neg_integer(), pos_integer(), String.t()) :: map()
  def offset_page(items, offset, page_size, scope) do
    next_offset = offset + page_size
    next_cursor = if length(items) > next_offset, do: encode_cursor(next_offset, scope)

    %{items: Enum.slice(items, offset, page_size), meta: %{next_cursor: next_cursor, page_size: page_size}}
  end

  @spec render_error(Plug.Conn.t(), error_reason()) :: Plug.Conn.t()
  def render_error(conn, reason) do
    {status, body} = error(reason)

    conn
    |> put_status(status)
    |> Controller.json(body)
  end

  @spec error(error_reason()) :: {pos_integer(), map()}
  def error(%Ecto.Changeset{} = changeset), do: error({:validation, changeset_errors(changeset)})

  def error({:validation, fields}) when is_map(fields), do: envelope(:validation_failed, fields)

  def error({:activation_blocked, code, fields}) when is_binary(code) and is_map(fields),
    do: {422, %{error: %{code: code, message: "Rule requirements for activation are not met", fields: fields}}}

  def error({:dependency, code}) when code in @dependency_codes,
    do: {503, %{error: %{code: code, message: "External service is unavailable or refused the request", fields: %{}}}}

  def error({:dependency, _code}), do: error({:dependency, "jira_unavailable"})

  def error(:confirmation_required), do: error({:confirmation_required, "confirmed"})

  def error({:confirmation_required, field}) when is_binary(field),
    do: envelope(:confirmation_required, %{field => ["must be true"]})

  def error(:invalid_idempotency_key), do: envelope(:invalid_idempotency_key, %{idempotency_key: ["must be a UUID"]})

  def error(reason) when is_map_key(@errors, reason), do: envelope(reason, %{})

  def error(_unknown), do: envelope(:action_unavailable, %{})

  @spec changeset_errors(Ecto.Changeset.t()) :: map()
  def changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn
        {key, value}, acc when is_binary(value) or is_number(value) or is_atom(value) ->
          String.replace(acc, "%{#{key}}", to_string(value))

        _other, acc ->
          acc
      end)
    end)
  end

  defp envelope(code, fields) do
    {status, message} = Map.fetch!(@errors, code)
    {status, %{error: %{code: Atom.to_string(code), message: message, fields: fields}}}
  end

  defp retry_allowed?(%IntegrationDelivery{operation: "analysis"}), do: false
  defp retry_allowed?(%IntegrationDelivery{status: "failed"}), do: true
  defp retry_allowed?(%IntegrationDelivery{status: "unknown", operation: operation}), do: operation in ["email", "sms"]
  defp retry_allowed?(%IntegrationDelivery{}), do: false

  defp page_size(nil, default), do: {:ok, default}

  defp page_size(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {size, ""} when size in 1..@max_page_size -> {:ok, size}
      _invalid -> {:error, :invalid_page_size}
    end
  end

  defp page_size(_value, _default), do: {:error, :invalid_page_size}

  defp encode_cursor(position, scope) do
    %{"p" => position, "s" => scope_hash(scope)}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil, _scope), do: {:ok, nil}

  defp decode_cursor(cursor, scope) when is_binary(cursor) do
    expected = scope_hash(scope)

    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"p" => position, "s" => ^expected}} <- Jason.decode(json) do
      {:ok, position}
    else
      _invalid -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_cursor, _scope), do: {:error, :invalid_cursor}

  defp scope_hash(scope) do
    :sha256 |> :crypto.hash(scope) |> binary_part(0, 8) |> Base.url_encode64(padding: false)
  end
end
