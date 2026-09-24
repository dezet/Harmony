defmodule SymphonyElixir.Intake.Diagnostics do
  @moduledoc """
  Read-only operational metrics of the Jira intake (spec §12) for the
  Diagnostics screen: effect queues per operation, backlog and its oldest
  waiting effect, unknown results, stale leases, the analysis pool against its
  claim limit, channel errors and the last success and scan time of every rule.

  Every number is aggregated in PostgreSQL. The snapshot carries only counts,
  timestamps, IDs, rule and project names and safe error codes: never payloads,
  recipients, case content or secrets.
  """

  import Ecto.Query

  alias SymphonyElixir.Intake
  alias SymphonyElixir.Intake.Outbox
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{AutomationRule, AutomationScan, IntegrationDelivery, Project}

  @operations ~w(linear_create analysis jira_comment email sms)
  @statuses ~w(pending retry_wait running paused unknown failed)
  @status_keys %{
    "pending" => :pending,
    "retry_wait" => :retry_wait,
    "running" => :running,
    "paused" => :paused,
    "unknown" => :unknown,
    "failed" => :failed
  }
  @waiting ~w(pending retry_wait paused)
  @error_statuses ~w(retry_wait unknown failed)
  @rule_limit 100
  @channel_error_limit 20

  @type queue :: %{
          operation: String.t(),
          pending: non_neg_integer(),
          retry_wait: non_neg_integer(),
          running: non_neg_integer(),
          paused: non_neg_integer(),
          unknown: non_neg_integer(),
          failed: non_neg_integer(),
          oldest_waiting_at: DateTime.t() | nil
        }

  @type t :: %{
          generated_at: DateTime.t(),
          switches: %{intake_enabled: boolean(), effects_enabled: boolean(), analysis_enabled: boolean()},
          queues: [queue()],
          backlog: %{total: non_neg_integer(), oldest_waiting_at: DateTime.t() | nil},
          unknown: non_neg_integer(),
          stale_leases: %{deliveries: non_neg_integer(), rules: non_neg_integer()},
          analysis: %{active: non_neg_integer(), limit: pos_integer(), queued: non_neg_integer()},
          channel_errors: [%{operation: String.t(), error_code: String.t(), count: pos_integer()}],
          rules: [map()]
        }

  @doc """
  Options: `:now` (defaults to the current UTC time) and `:intake_enabled`,
  `:effects_enabled`, `:analysis_enabled` (default to the runtime switches).
  """
  @spec snapshot(keyword()) :: t()
  def snapshot(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    queues = queues()

    %{
      generated_at: now,
      switches: switches(opts),
      queues: queues,
      backlog: backlog(queues),
      unknown: Enum.sum(Enum.map(queues, & &1.unknown)),
      stale_leases: %{deliveries: stale_delivery_leases(now), rules: stale_rule_leases(now)},
      analysis: analysis_pool(queues, now),
      channel_errors: channel_errors(),
      rules: rules()
    }
  end

  defp switches(opts) do
    %{
      intake_enabled: Keyword.get_lazy(opts, :intake_enabled, fn -> Intake.enabled?() end),
      effects_enabled: Keyword.get_lazy(opts, :effects_enabled, fn -> Intake.effects_enabled?() end),
      analysis_enabled: Keyword.get_lazy(opts, :analysis_enabled, fn -> Intake.analysis_enabled?() end)
    }
  end

  defp queues do
    rows =
      Repo.all(
        from(d in IntegrationDelivery,
          where: d.status in @statuses,
          group_by: [d.operation, d.status],
          select: {d.operation, d.status, count(d.id), min(d.inserted_at)}
        )
      )

    Enum.map(@operations, fn operation ->
      own = Enum.filter(rows, &(elem(&1, 0) == operation))
      counts = Map.new(@statuses, fn status -> {Map.fetch!(@status_keys, status), status_count(own, status)} end)

      oldest =
        own
        |> Enum.filter(fn {_operation, status, _count, _oldest} -> status in @waiting end)
        |> Enum.map(fn {_operation, _status, _count, oldest} -> oldest end)
        |> earliest()

      Map.merge(counts, %{operation: operation, oldest_waiting_at: oldest})
    end)
  end

  defp status_count(rows, status) do
    Enum.find_value(rows, 0, fn
      {_operation, ^status, count, _oldest} -> count
      _row -> nil
    end)
  end

  defp backlog(queues) do
    %{
      total: Enum.sum(Enum.map(queues, &(&1.pending + &1.retry_wait + &1.paused))),
      oldest_waiting_at: queues |> Enum.map(& &1.oldest_waiting_at) |> earliest()
    }
  end

  defp earliest(datetimes) do
    datetimes
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp stale_delivery_leases(now) do
    Repo.aggregate(
      from(d in IntegrationDelivery, where: d.status == "running" and (is_nil(d.lease_until) or d.lease_until <= ^now)),
      :count,
      :id
    )
  end

  defp stale_rule_leases(now) do
    Repo.aggregate(
      from(r in AutomationRule, where: not is_nil(r.lease_token) and (is_nil(r.lease_until) or r.lease_until <= ^now)),
      :count,
      :id
    )
  end

  defp analysis_pool(queues, now) do
    analysis = Enum.find(queues, &(&1.operation == "analysis"))

    active =
      Repo.aggregate(
        from(d in IntegrationDelivery,
          where: d.operation == "analysis" and d.status == "running" and d.lease_until > ^now
        ),
        :count,
        :id
      )

    %{active: active, limit: Outbox.claim_limits().analysis, queued: analysis.pending + analysis.retry_wait}
  end

  defp channel_errors do
    Repo.all(
      from(d in IntegrationDelivery,
        where: d.status in @error_statuses and not is_nil(d.last_error_code),
        group_by: [d.operation, d.last_error_code],
        order_by: [desc: count(d.id), asc: d.operation, asc: d.last_error_code],
        limit: @channel_error_limit,
        select: %{operation: d.operation, error_code: d.last_error_code, count: count(d.id)}
      )
    )
  end

  defp rules do
    last_scans =
      from(s in AutomationScan,
        where: s.mode in ["baseline", "poll"] and not is_nil(s.finished_at),
        distinct: s.rule_id,
        order_by: [asc: s.rule_id, desc: s.finished_at],
        select: %{
          rule_id: s.rule_id,
          mode: s.mode,
          status: s.status,
          started_at: s.started_at,
          finished_at: s.finished_at,
          duration_ms: fragment("round(EXTRACT(EPOCH FROM (? - ?)) * 1000)::bigint", s.finished_at, s.started_at),
          error_code: s.error_code
        }
      )

    from(r in AutomationRule,
      join: p in Project,
      on: p.id == r.project_id,
      left_join: s in subquery(last_scans),
      on: s.rule_id == r.id,
      order_by: [asc: r.name, asc: r.id],
      limit: @rule_limit,
      select: %{
        id: r.id,
        name: r.name,
        project: %{id: p.id, slug: p.slug, name: coalesce(p.display_name, p.slug)},
        enabled: r.enabled,
        activation_status: r.activation_status,
        last_success_at: r.last_success_at,
        next_poll_at: r.next_poll_at,
        last_error_code: r.last_error_code,
        scan: s
      }
    )
    |> Repo.all()
    |> Enum.map(fn %{scan: scan} = rule ->
      rule
      |> Map.delete(:scan)
      |> Map.put(:last_scan, last_scan(scan))
    end)
  end

  # A rule without a finished scan joins no row of the subquery.
  defp last_scan(%{rule_id: rule_id} = scan) when is_binary(rule_id), do: Map.delete(scan, :rule_id)
  defp last_scan(_missing), do: nil
end
