defmodule SymphonyElixir.Intake.Poller do
  @moduledoc "Runs durable, generation-scoped Jira baseline and polling scans."

  import Ecto.Query

  alias SymphonyElixir.Intake
  alias SymphonyElixir.Intake.Matcher
  alias SymphonyElixir.Jira.CloudClient
  alias SymphonyElixir.Repo

  alias SymphonyElixir.Storage.{AutomationRule, AutomationScan, IntegrationConnection}

  @max_issues 10_000
  @max_duration_ms 10 * 60 * 1_000
  @scan_lease_seconds 120
  @scan_heartbeat_ms 30 * 1_000
  @scan_claim_lock_id 1_212_978_509
  @max_active_scans 2

  @spec run(binary(), keyword()) :: {:ok, AutomationScan.t()} | {:error, term()}
  def run(rule_id, opts \\ []) when is_binary(rule_id) do
    case start_scan(rule_id, opts) do
      {:ok, context} ->
        case Intake.analysis_profile(opts) do
          {:ok, profile} ->
            case fetch_issues(context, profile, opts) do
              {:ok, _issues} ->
                case finish_success(context, opts) do
                  {:error, :effects_disabled} -> finish_failure(context, :effects_disabled, opts)
                  result -> result
                end

              {:error, reason} ->
                finish_failure(context, reason, opts)
            end

          {:error, reason} ->
            finish_failure(context, reason, opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec heartbeat(binary(), binary(), binary(), keyword()) :: :ok | {:error, term()}
  def heartbeat(rule_id, scan_id, lease_token, opts \\ [])
      when is_binary(rule_id) and is_binary(scan_id) and is_binary(lease_token) do
    now = current_time(opts)

    result =
      Repo.transaction(fn ->
        scan = Repo.one(from(scan in AutomationScan, where: scan.id == ^scan_id, lock: "FOR UPDATE"))
        rule = Repo.one(from(rule in AutomationRule, where: rule.id == ^rule_id, lock: "FOR UPDATE"))
        context = %{scan: scan, lease_token: lease_token}

        if still_owner?(scan, rule, context, now) do
          rule
          |> AutomationRule.changeset(%{
            lease_until: DateTime.add(now, @scan_lease_seconds, :second),
            lock_version: rule.lock_version + 1
          })
          |> Repo.update!()

          :ok
        else
          Repo.rollback(:stale_generation)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_scan(rule_id, opts) do
    now = current_time(opts)
    uuid_fun = Keyword.get(opts, :uuid_fun, &Ecto.UUID.generate/0)

    case Repo.transaction(fn ->
           rule = Repo.one(from(rule in AutomationRule, where: rule.id == ^rule_id, lock: "FOR UPDATE SKIP LOCKED"))

           with %AutomationRule{} <- rule,
                :ok <- ensure_effects_enabled(),
                :ok <- validate_start(rule, now),
                :ok <- claim_scan_capacity(now) do
             mode = if is_nil(rule.baseline_generation), do: "baseline", else: "poll"
             generation = uuid_fun.()
             lease_token = uuid_fun.()
             lease_until = DateTime.add(now, @scan_lease_seconds, :second)

             scan =
               %AutomationScan{}
               |> AutomationScan.changeset(%{
                 rule_id: rule.id,
                 rule_config_version: rule.config_version,
                 mode: mode,
                 status: "running",
                 generation: generation,
                 started_at: now,
                 match_count: 0,
                 accepted_count: 0
               })
               |> Repo.insert!()

             rule
             |> AutomationRule.changeset(%{
               last_started_at: now,
               last_error_code: nil,
               lease_token: lease_token,
               lease_until: lease_until,
               lock_version: rule.lock_version + 1
             })
             |> Repo.update!()

             %{scan: scan, rule: rule, lease_token: lease_token}
           else
             nil ->
               reason =
                 if Repo.exists?(from(rule in AutomationRule, where: rule.id == ^rule_id)),
                   do: :scan_in_progress,
                   else: :not_found

               Repo.rollback(reason)

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, context} -> {:ok, context}
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_scan_capacity(now) do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@scan_claim_lock_id])

    active_scans =
      Repo.aggregate(
        from(rule in AutomationRule,
          where: not is_nil(rule.lease_token) and not is_nil(rule.lease_until) and rule.lease_until > ^now
        ),
        :count,
        :id
      )

    if active_scans < @max_active_scans, do: :ok, else: {:error, :scan_capacity}
  end

  defp validate_start(rule, now) do
    if Intake.effects_enabled?(), do: validate_start_state(rule, now), else: {:error, :effects_disabled}
  end

  defp validate_start_state(%AutomationRule{lease_token: token, lease_until: until}, now)
       when is_binary(token) and not is_nil(until) do
    if DateTime.compare(until, now) == :gt, do: {:error, :scan_in_progress}, else: :ok
  end

  defp validate_start_state(%AutomationRule{baseline_generation: nil, activation_status: "activating", enabled: false}, _now),
    do: :ok

  defp validate_start_state(%AutomationRule{baseline_generation: generation, enabled: true}, _now)
       when not is_nil(generation),
       do: :ok

  defp validate_start_state(%AutomationRule{}, _now), do: {:error, :rule_not_active}

  defp fetch_issues(context, profile, opts) do
    with %IntegrationConnection{} = connection <- Repo.get(IntegrationConnection, context.rule.jira_connection_id),
         {:ok, client_opts} <- client_opts(connection, opts) do
      started_ms = monotonic_time(opts)
      result_count = :counters.new(1, [:atomics])
      last_heartbeat_ms = :atomics.new(1, [])
      :atomics.put(last_heartbeat_ms, 1, started_ms)

      page_fun = fn issues ->
        count = length(issues)
        total = :counters.get(result_count, 1) + count

        cond do
          monotonic_time(opts) - started_ms >= Keyword.get(opts, :max_duration_ms, @max_duration_ms) ->
            {:error, %{kind: :scan_limit_exceeded}}

          total > Keyword.get(opts, :max_issues, @max_issues) ->
            {:error, %{kind: :scan_limit_exceeded}}

          true ->
            with :ok <- ensure_effects_enabled(),
                 :ok <- heartbeat_if_due(context, last_heartbeat_ms, opts) do
              matcher_opts =
                opts
                |> Keyword.put(:lease_token, context.lease_token)
                |> Keyword.put(:analysis_profile, profile)

              case Matcher.persist_page(context.scan, issues, matcher_opts) do
                {:ok, _counts} ->
                  :counters.add(result_count, 1, count)
                  :ok

                {:error, reason} ->
                  {:error, reason}
              end
            end
        end
      end

      search_opts = Keyword.put(client_opts, :page_fun, page_fun)

      result =
        case context.rule.source_type do
          "board" -> CloudClient.search_board_issues(context.rule.source_id, context.rule.priority_ids, search_opts)
          "filter" -> CloudClient.search_filter_issues(context.rule.source_id, context.rule.priority_ids, search_opts)
        end

      if match?({:ok, _issues}, result) and
           monotonic_time(opts) - started_ms >= Keyword.get(opts, :max_duration_ms, @max_duration_ms) do
        {:error, %{kind: :scan_limit_exceeded}}
      else
        result
      end
    else
      nil -> {:error, :jira_connection_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp client_opts(connection, opts) do
    settings = connection.settings || %{}

    cond do
      not connection.enabled ->
        {:error, :jira_connection_disabled}

      not is_binary(connection.secret) or String.trim(connection.secret) == "" ->
        {:error, :jira_credentials_unset}

      true ->
        client_opts = [
          token: connection.secret,
          auth_mode: setting(settings, "auth_mode"),
          site_url: setting(settings, "site_url"),
          account_email: setting(settings, "account_email"),
          cloud_id: setting(settings, "cloud_id")
        ]

        {:ok, Keyword.merge(client_opts, Keyword.take(opts, [:request_fun, :timeout_ms]))}
    end
  end

  defp finish_success(context, opts) do
    now = current_time(opts)

    case Repo.transaction(fn ->
           scan = Repo.one(from(scan in AutomationScan, where: scan.id == ^context.scan.id, lock: "FOR UPDATE"))
           rule = Repo.one(from(rule in AutomationRule, where: rule.id == ^context.rule.id, lock: "FOR UPDATE"))

           cond do
             not still_owner?(scan, rule, context, now) ->
               cancel_scan!(scan, now)
               clear_stale_lease(rule, context.lease_token)
               {:error, :stale_generation}

             not Intake.effects_enabled?() ->
               Repo.rollback(:effects_disabled)

             true ->
               finished_scan =
                 scan
                 |> AutomationScan.changeset(%{status: "succeeded", finished_at: now, error_code: nil})
                 |> Repo.update!()

               rule_attrs = %{
                 last_success_at: now,
                 next_poll_at: DateTime.add(now, rule.interval_seconds, :second),
                 last_error_code: nil,
                 lease_token: nil,
                 lease_until: nil,
                 lock_version: rule.lock_version + 1
               }

               rule_attrs =
                 if scan.mode == "baseline" do
                   Map.merge(rule_attrs, %{
                     enabled: true,
                     activation_status: "idle",
                     activated_at: rule.activated_at || now,
                     baseline_generation: scan.generation,
                     baseline_complete_at: now
                   })
                 else
                   rule_attrs
                 end

               rule
               |> AutomationRule.changeset(rule_attrs)
               |> Repo.update!()

               {:ok, finished_scan}
           end
         end) do
      {:ok, {:ok, scan}} -> {:ok, scan}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_failure(context, reason, opts) do
    now = current_time(opts)
    error_code = error_code(reason)
    status = if error_code == "stale_generation", do: "cancelled", else: "failed"

    case Repo.transaction(fn ->
           scan = Repo.one(from(scan in AutomationScan, where: scan.id == ^context.scan.id, lock: "FOR UPDATE"))
           rule = Repo.one(from(rule in AutomationRule, where: rule.id == ^context.rule.id, lock: "FOR UPDATE"))

           if scan && scan.status == "running" do
             scan
             |> AutomationScan.changeset(%{status: status, finished_at: now, error_code: error_code})
             |> Repo.update!()
           end

           if rule && rule.lease_token == context.lease_token do
             attrs = %{
               last_error_code: error_code,
               next_poll_at: next_poll_at(now, rule.interval_seconds, reason),
               lease_token: nil,
               lease_until: nil,
               lock_version: rule.lock_version + 1
             }

             rule
             |> AutomationRule.changeset(attrs)
             |> Repo.update!()
           end

           {:error, error_code}
         end) do
      {:ok, {:error, ^error_code}} -> {:error, reason}
      {:error, transaction_reason} -> {:error, transaction_reason}
    end
  end

  defp still_owner?(%AutomationScan{} = scan, %AutomationRule{} = rule, context, now) do
    scan.status == "running" and scan.generation == context.scan.generation and
      scan.rule_config_version == rule.config_version and rule.lease_token == context.lease_token and
      not is_nil(rule.lease_until) and DateTime.compare(rule.lease_until, now) == :gt and
      if(scan.mode == "baseline",
        do: not rule.enabled and rule.activation_status == "activating" and is_nil(rule.baseline_generation),
        else: rule.enabled and not is_nil(rule.baseline_generation)
      )
  end

  defp still_owner?(_scan, _rule, _context, _now), do: false

  defp heartbeat_if_due(context, last_heartbeat_ms, opts) do
    now_ms = monotonic_time(opts)
    last_ms = :atomics.get(last_heartbeat_ms, 1)

    if now_ms - last_ms >= @scan_heartbeat_ms do
      case heartbeat(context.rule.id, context.scan.id, context.lease_token, opts) do
        :ok ->
          :atomics.put(last_heartbeat_ms, 1, now_ms)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp cancel_scan!(nil, _now), do: :ok

  defp cancel_scan!(scan, now) do
    if scan.status == "running" do
      scan
      |> AutomationScan.changeset(%{status: "cancelled", finished_at: now, error_code: "stale_generation"})
      |> Repo.update!()
    end
  end

  defp clear_stale_lease(%AutomationRule{lease_token: lease_token} = rule, lease_token) do
    rule
    |> AutomationRule.changeset(%{
      lease_token: nil,
      lease_until: nil,
      last_error_code: "stale_generation",
      lock_version: rule.lock_version + 1
    })
    |> Repo.update!()
  end

  defp clear_stale_lease(_rule, _lease_token), do: :ok

  defp error_code(%{kind: :scan_limit_exceeded}), do: "scan_limit_exceeded"
  defp error_code(:stale_generation), do: "stale_generation"
  defp error_code(:scan_limit_exceeded), do: "scan_limit_exceeded"
  defp error_code(:malformed_issue), do: "malformed_issue"
  defp error_code(:invalid_jira_connection), do: "invalid_jira_connection"
  defp error_code(:jira_connection_disabled), do: "jira_connection_disabled"
  defp error_code(:jira_credentials_unset), do: "jira_credentials_unset"
  defp error_code(:analysis_profile_unavailable), do: "analysis_profile_unavailable"
  defp error_code(%{kind: kind}) when is_atom(kind), do: Atom.to_string(kind)
  defp error_code({:error, reason}), do: error_code(reason)
  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "jira_scan_failed"

  defp next_poll_at(now, interval_seconds, %{kind: :http_status, status: 429, retry_after: retry_after}) do
    DateTime.add(now, max(interval_seconds, retry_after_seconds(retry_after, now)), :second)
  end

  defp next_poll_at(now, interval_seconds, _reason), do: DateTime.add(now, interval_seconds, :second)

  defp retry_after_seconds(value, now) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> retry_after_http_date(value, now)
    end
  end

  defp retry_after_seconds(_value, _now), do: 0

  defp retry_after_http_date(value, now) do
    with {{year, month, day}, {hour, minute, second}} <-
           :httpd_util.convert_request_date(String.to_charlist(value)),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, naive} <- NaiveDateTime.new(date, time) do
      deadline = DateTime.from_naive!(naive, "Etc/UTC")

      deadline
      |> DateTime.diff(now, :microsecond)
      |> ceil_seconds()
    else
      _ -> 0
    end
  rescue
    _error -> 0
  end

  defp ceil_seconds(microseconds) when microseconds > 0, do: div(microseconds + 999_999, 1_000_000)
  defp ceil_seconds(_microseconds), do: 0

  defp ensure_effects_enabled do
    if Intake.effects_enabled?(), do: :ok, else: {:error, :effects_disabled}
  end

  defp setting(settings, key) when is_map(settings), do: Map.get(settings, key) || Map.get(settings, String.to_atom(key))
  defp setting(_settings, _key), do: nil

  defp current_time(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _ -> DateTime.utc_now()
    end
    |> DateTime.truncate(:microsecond)
  end

  defp monotonic_time(opts) do
    case Keyword.get(opts, :monotonic_clock) do
      clock when is_function(clock, 0) -> clock.()
      _ -> System.monotonic_time(:millisecond)
    end
  end
end
