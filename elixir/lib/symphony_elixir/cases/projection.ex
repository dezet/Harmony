defmodule SymphonyElixir.Cases.Projection do
  @moduledoc """
  PostgreSQL projection of Jira intake cases and existing work runs into one
  list of `CaseSummary` rows (spec §11.3).

  Both sources are read, never copied: `intake_cases` with their current
  effects, and the newest `work_runs` record per
  `(project_id, coalesce(linear_issue_id, dedupe_key, id::text))`. Work runs
  of type `jira_analysis` and runs linked to an intake case through the
  reserved Linear issue ID are not separate cards.

  The SQL computes a `state` code per row and derives the column from it, so
  filtering, paging and counting stay in PostgreSQL. Elixir only turns one
  page of rows into the presented summary (labels, attention, priority tone).
  """

  alias SymphonyElixir.Repo

  @type filters :: %{
          optional(:project_id) => binary() | nil,
          optional(:column) => String.t() | nil,
          optional(:q) => String.t() | nil
        }

  @type row :: %{required(atom()) => term()}

  @detected_states ~w(jira_waiting_linear jira_queued jira_repair_waiting run_queued run_retrying repair_queued repair_retrying)
  @analyzing_states ~w(jira_analyzing run_running repair_running)
  @handed_off_states ~w(
    jira_handed_off run_completed run_succeeded run_handed_off run_cancelled
    repair_completed repair_succeeded repair_handed_off repair_cancelled
  )

  @columns ~w(detected analyzing decision handed_off)

  @row_fields ~w(
    ref kind project_id project_slug project_name project_color title jira_key jira_url linear_identifier linear_url
    priority_id priority_label priority_rank legacy_priority case_column state raw_status run_status run_type
    execution_mode detected_at updated_at paused failure_operation
  )a

  @operation_names %{
    "linear_create" => "Linear",
    "email" => "e-mail",
    "sms" => "SMS",
    "analysis" => "analiza",
    "jira_comment" => "komentarz Jira"
  }

  @doc "Columns of the Kanban board in their fixed order."
  @spec columns() :: [String.t()]
  def columns, do: @columns

  @doc """
  One page of rows ordered by `detected_at DESC, ref ASC`, starting after the
  keyset position. Fetches `limit` rows; the caller asks for one extra row to
  know whether a next page exists.
  """
  @spec page(filters(), pos_integer(), {DateTime.t(), String.t()} | nil) :: [row()]
  def page(filters, limit, position) do
    {where, params} = where_clause(filters, [])
    {keyset, params} = keyset_clause(position, params)
    {limit_param, params} = bind(params, limit)

    sql = """
    #{projection_sql(:all)}
    SELECT #{select_list()}
    FROM projected x
    JOIN projects p ON p.id = x.project_id
    WHERE #{where} AND #{keyset}
    ORDER BY x.detected_at DESC, x.ref ASC
    LIMIT #{limit_param}
    """

    query_rows(sql, params)
  end

  @doc """
  Totals in one query: `total` for all filters, and per-column counts for the
  project and search only (the active column/filter does not change them).
  """
  @spec counts(filters()) :: %{total: non_neg_integer(), counts: map()}
  def counts(filters) do
    {where, params} = where_clause(Map.put(filters, :column, nil), [])
    {column, params} = column_clause(Map.get(filters, :column), params)

    sql = """
    #{projection_sql(:all)}
    SELECT
      count(*) FILTER (WHERE #{column}),
      count(*),
      count(*) FILTER (WHERE x.case_column = 'decision'),
      count(*) FILTER (WHERE x.case_column = 'analyzing'),
      count(*) FILTER (WHERE x.case_column = 'handed_off'),
      count(*) FILTER (WHERE x.case_column = 'detected')
    FROM projected x
    WHERE #{where}
    """

    %{rows: [[total, all, decision, analysis, done, detected]]} = Repo.query!(sql, params)

    %{total: total, counts: %{all: all, decision: decision, analysis: analysis, done: done, detected: detected}}
  end

  @doc "Number of cases per project, including projects without cases."
  @spec project_counts() :: [%{project_id: binary(), total: non_neg_integer()}]
  def project_counts do
    sql = """
    #{projection_sql(:all)}
    SELECT p.id::text, count(x.ref)
    FROM projects p
    LEFT JOIN projected x ON x.project_id = p.id
    GROUP BY p.id, p.slug
    ORDER BY p.slug
    """

    %{rows: rows} = Repo.query!(sql, [])
    Enum.map(rows, fn [project_id, total] -> %{project_id: project_id, total: total} end)
  end

  @doc "The projected row of one Jira case or work run, or nil when it is not a card."
  @spec fetch({:jira | :run, binary()}) :: row() | nil
  def fetch({kind, id}) do
    sql = """
    #{projection_sql({kind, "$1"})}
    SELECT #{select_list()}
    FROM projected x
    JOIN projects p ON p.id = x.project_id
    """

    sql |> query_rows([Ecto.UUID.dump!(id)]) |> List.first()
  end

  @doc "Presents one projected row as a `CaseSummary`."
  @spec summary(row()) :: map()
  def summary(row) do
    %{
      ref: row.ref,
      kind: row.kind,
      project: %{id: row.project_id, slug: row.project_slug, name: row.project_name, color: row.project_color},
      title: row.title,
      jira: link(:key, row.jira_key, row.jira_url),
      linear: link(:identifier, row.linear_identifier, row.linear_url),
      priority: priority(row),
      column: row.case_column,
      status_label: status_label(row),
      execution_mode: row.execution_mode,
      detected_at: row.detected_at,
      updated_at: row.updated_at,
      attention: attention(row)
    }
  end

  # ── SQL ──────────────────────────────────────────────────────────────────

  # `scope` is `:all` for the list, or `{:jira | :run, param}` to project a
  # single record regardless of newer runs of the same source.
  defp projection_sql(scope) do
    """
    WITH effects AS (
      SELECT
        d.case_id,
        bool_or(d.status = 'paused') AS paused,
        bool_or(
          d.operation = 'jira_comment' AND d.status = 'succeeded'
            AND COALESCE(d.provider_id, '') <> '' AND d.sent_at IS NOT NULL
        ) AS published,
        (array_agg(d.operation ORDER BY #{severity()}, d.updated_at DESC, d.id)
          FILTER (WHERE d.status IN ('failed', 'unknown', 'retry_wait')))[1] AS failure_operation,
        (array_agg(d.status ORDER BY #{severity()}, d.updated_at DESC, d.id)
          FILTER (WHERE d.status IN ('failed', 'unknown', 'retry_wait')))[1] AS failure_status
      FROM integration_deliveries d
      JOIN intake_cases c ON c.id = d.case_id
      WHERE #{jira_scope(scope)} AND #{current_effect()}
      GROUP BY d.case_id
    ),
    implementations AS (
      SELECT DISTINCT ON (w.linear_issue_id) w.linear_issue_id, w.status, w.type, #{run_error("w")} AS error
      FROM work_runs w
      JOIN intake_cases c ON c.linear_issue_id::text = w.linear_issue_id AND c.repair_approved_at IS NOT NULL
      WHERE #{jira_scope(scope)} AND w.type <> 'jira_analysis'
      ORDER BY w.linear_issue_id, w.inserted_at DESC, w.id DESC
    ),
    jira_cases AS (
      SELECT
        'jira_' || c.id::text AS ref,
        'jira_intake'::text AS kind,
        c.project_id,
        c.title,
        c.jira_key,
        c.jira_url,
        c.linear_identifier AS search_linear,
        CASE WHEN #{confirmed_linear()} THEN c.linear_identifier END AS linear_identifier,
        CASE WHEN #{confirmed_linear()} THEN c.linear_url END AS linear_url,
        c.priority_id,
        c.priority_name AS priority_label,
        #{priority_rank()} AS priority_rank,
        NULL::text AS legacy_priority,
        c.detected_at,
        c.updated_at,
        CASE WHEN c.repair_approved_at IS NOT NULL THEN 'repair_approved' ELSE 'analysis_only' END AS execution_mode,
        CASE
          WHEN c.analysis_status = 'failed' THEN 'jira_analysis_failed'
          WHEN fx.failure_operation = 'jira_comment' THEN 'jira_publication_' || fx.failure_status
          WHEN fx.failure_status IS NOT NULL THEN 'jira_delivery_' || fx.failure_status
          WHEN c.repair_approved_at IS NOT NULL AND impl.status IS NULL THEN 'jira_repair_waiting'
          WHEN c.repair_approved_at IS NOT NULL THEN 'repair_' || #{legacy_state("impl.status", "impl.error")}
          WHEN c.analysis_status = 'running' THEN 'jira_analyzing'
          WHEN c.analysis_status = 'queued' AND c.linear_confirmed_at IS NULL THEN 'jira_waiting_linear'
          WHEN c.analysis_status = 'queued' THEN 'jira_queued'
          WHEN c.analysis_status IN ('ready', 'needs_input') AND c.acknowledged_at IS NOT NULL AND fx.published
            THEN 'jira_handed_off'
          WHEN c.analysis_status = 'ready' THEN 'jira_ready'
          WHEN c.analysis_status = 'needs_input' THEN 'jira_needs_input'
          ELSE 'jira_unknown'
        END AS state,
        c.analysis_status AS raw_status,
        impl.status AS run_status,
        impl.type AS run_type,
        COALESCE(fx.paused, FALSE) AS paused,
        fx.failure_operation
      FROM intake_cases c
      LEFT JOIN effects fx ON fx.case_id = c.id
      LEFT JOIN implementations impl ON c.repair_approved_at IS NOT NULL AND impl.linear_issue_id = c.linear_issue_id::text
      WHERE #{jira_scope(scope)}
    ),
    runs AS (
      #{runs_sql(scope)}
    ),
    agent_cases AS (
      SELECT
        'run_' || w.id::text AS ref,
        'agent_work'::text AS kind,
        w.project_id,
        COALESCE(
          NULLIF(w.payload->>'title', ''),
          NULLIF(w.payload #>> '{issue,title}', ''),
          NULLIF(w.linear_identifier, ''),
          w.type || ' · ' || left(w.id::text, 8)
        ) AS title,
        NULL::text AS jira_key,
        NULL::text AS jira_url,
        w.linear_identifier AS search_linear,
        CASE WHEN #{run_linear()} THEN w.linear_identifier END AS linear_identifier,
        CASE WHEN #{run_linear()} THEN w.linear_url END AS linear_url,
        NULL::text AS priority_id,
        NULL::text AS priority_label,
        NULL::bigint AS priority_rank,
        w.payload #>> '{issue,priority}' AS legacy_priority,
        w.inserted_at AS detected_at,
        w.updated_at,
        'existing_workflow'::text AS execution_mode,
        'run_' || #{legacy_state("w.status", run_error("w"))} AS state,
        w.status AS raw_status,
        w.status AS run_status,
        w.type AS run_type,
        FALSE AS paused,
        NULL::text AS failure_operation
      FROM runs w
    ),
    projected AS (
      SELECT u.*, #{column_sql("u.state")} AS case_column
      FROM (SELECT * FROM jira_cases UNION ALL SELECT * FROM agent_cases) u
    )
    """
  end

  defp confirmed_linear do
    "c.linear_confirmed_at IS NOT NULL AND COALESCE(c.linear_identifier, '') <> '' AND COALESCE(c.linear_url, '') <> ''"
  end

  # Zero-based position of the case priority in the Jira ranking stored in the
  # rule snapshot at qualification; NULL without a ranking or outside it.
  defp priority_rank do
    """
    (CASE WHEN jsonb_typeof(c.rule_snapshot -> 'priority_ranking') = 'array' THEN
      (SELECT r.ord - 1
        FROM jsonb_array_elements_text(c.rule_snapshot -> 'priority_ranking') WITH ORDINALITY AS r(id, ord)
        WHERE r.id = c.priority_id
        ORDER BY r.ord
        LIMIT 1)
    END)
    """
  end

  defp run_linear, do: "COALESCE(w.linear_identifier, '') <> '' AND COALESCE(w.linear_url, '') <> ''"

  defp severity, do: "CASE d.status WHEN 'failed' THEN 0 WHEN 'unknown' THEN 1 ELSE 2 END"

  # Analysis and comment effects count only for the current analysis version.
  defp current_effect do
    """
    (d.operation NOT IN ('analysis', 'jira_comment')
      OR d.dedupe_key = 'case:' || c.id::text || ':analysis:' || c.analysis_version::text
      OR d.dedupe_key = 'case:' || c.id::text || ':jira-comment:' || c.analysis_version::text)
    """
  end

  defp run_error(alias_name) do
    "NULLIF(COALESCE(#{alias_name}.payload->>'error_code', #{alias_name}.payload->>'error'), '')"
  end

  defp legacy_state(status, error) do
    """
    (CASE
      WHEN #{status} = 'running' THEN 'running'
      WHEN #{status} IN ('queued', 'retrying') AND #{error} IS NULL THEN #{status}
      WHEN #{status} IN ('queued', 'retrying') THEN 'retry_error'
      WHEN #{status} IN ('blocked', 'failed', 'stopped', 'human_review') THEN #{status}
      WHEN #{status} IN ('completed', 'succeeded', 'handed_off', 'cancelled') THEN #{status}
      ELSE 'unknown'
    END)
    """
  end

  defp column_sql(state) do
    """
    (CASE
      WHEN #{state} IN (#{sql_list(@detected_states)}) THEN 'detected'
      WHEN #{state} IN (#{sql_list(@analyzing_states)}) THEN 'analyzing'
      WHEN #{state} IN (#{sql_list(@handed_off_states)}) THEN 'handed_off'
      ELSE 'decision'
    END)
    """
  end

  defp sql_list(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  defp jira_scope(:all), do: "TRUE"
  defp jira_scope({:jira, param}), do: "c.id = #{param}"
  defp jira_scope({:run, _param}), do: "FALSE"

  defp runs_sql(:all) do
    """
    SELECT DISTINCT ON (w.project_id, #{source_key()}) w.*
      FROM work_runs w
      WHERE #{visible_run()}
      ORDER BY w.project_id, #{source_key()}, w.inserted_at DESC, w.id DESC
    """
  end

  defp runs_sql({:run, param}), do: "SELECT w.* FROM work_runs w WHERE w.id = #{param} AND #{visible_run()}"
  defp runs_sql({:jira, _param}), do: "SELECT w.* FROM work_runs w WHERE FALSE"

  defp source_key, do: "COALESCE(w.linear_issue_id, w.dedupe_key, w.id::text)"

  defp visible_run do
    "w.type <> 'jira_analysis' AND NOT EXISTS (SELECT 1 FROM intake_cases ic WHERE ic.linear_issue_id::text = w.linear_issue_id)"
  end

  defp select_list do
    """
    x.ref, x.kind, x.project_id::text, p.slug, COALESCE(p.display_name, p.slug), p.ui_color, x.title, x.jira_key, x.jira_url,
    x.linear_identifier, x.linear_url, x.priority_id, x.priority_label, x.priority_rank, x.legacy_priority,
    x.case_column, x.state, x.raw_status, x.run_status, x.run_type, x.execution_mode,
    x.detected_at, x.updated_at, x.paused, x.failure_operation
    """
  end

  defp where_clause(filters, params) do
    {project, params} = project_clause(Map.get(filters, :project_id), params)
    {column, params} = column_clause(Map.get(filters, :column), params)
    {search, params} = search_clause(Map.get(filters, :q), params)
    {Enum.join([project, column, search], " AND "), params}
  end

  defp project_clause(nil, params), do: {"TRUE", params}

  defp project_clause(project_id, params) do
    {param, params} = bind(params, Ecto.UUID.dump!(project_id))
    {"x.project_id = #{param}", params}
  end

  defp column_clause(nil, params), do: {"TRUE", params}

  defp column_clause(column, params) when column in @columns do
    {param, params} = bind(params, column)
    {"x.case_column = #{param}", params}
  end

  defp search_clause(nil, params), do: {"TRUE", params}

  defp search_clause(q, params) do
    {param, params} = bind(params, "%" <> escape_like(q) <> "%")
    {"(x.title ILIKE #{param} OR x.jira_key ILIKE #{param} OR x.search_linear ILIKE #{param})", params}
  end

  defp escape_like(value), do: String.replace(value, ["\\", "%", "_"], &("\\" <> &1))

  defp keyset_clause(nil, params), do: {"TRUE", params}

  defp keyset_clause({%DateTime{} = detected_at, ref}, params) do
    {date_param, params} = bind(params, DateTime.to_naive(detected_at))
    {ref_param, params} = bind(params, ref)
    {"(x.detected_at < #{date_param} OR (x.detected_at = #{date_param} AND x.ref > #{ref_param}))", params}
  end

  defp bind(params, value) do
    params = params ++ [value]
    {"$#{length(params)}", params}
  end

  defp query_rows(sql, params) do
    %{rows: rows} = Repo.query!(sql, params)

    Enum.map(rows, fn values ->
      @row_fields
      |> Enum.zip(values)
      |> Map.new()
      |> Map.update!(:detected_at, &utc/1)
      |> Map.update!(:updated_at, &utc/1)
    end)
  end

  defp utc(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp utc(%DateTime{} = value), do: value

  # ── presentation of one row ──────────────────────────────────────────────

  defp link(_key, nil, _url), do: nil
  defp link(_key, _value, nil), do: nil
  defp link(key, value, url), do: %{key => value, url: url}

  # Jira priorities keep their ID and name. The tone comes only from the Jira
  # ranking stored at rule activation: the first priority is critical, the
  # next one high, the rest normal. Without a ranking every tone is normal;
  # names are never interpreted.
  defp priority(%{kind: "jira_intake"} = row), do: %{id: row.priority_id, label: row.priority_label, tone: jira_tone(row.priority_rank)}

  defp priority(%{legacy_priority: raw}) do
    case raw && Integer.parse(raw) do
      {1, ""} -> %{id: "1", label: "Krytyczny", tone: "critical"}
      {2, ""} -> %{id: "2", label: "Wysoki", tone: "high"}
      {3, ""} -> %{id: "3", label: "Średni", tone: "normal"}
      {4, ""} -> %{id: "4", label: "Niski", tone: "normal"}
      _none -> %{id: nil, label: "Brak priorytetu", tone: "normal"}
    end
  end

  defp jira_tone(0), do: "critical"
  defp jira_tone(1), do: "high"
  defp jira_tone(_rank_or_nil), do: "normal"

  @jira_labels %{
    "jira_waiting_linear" => "Oczekuje na Linear",
    "jira_queued" => "Oczekuje na analizę",
    "jira_analyzing" => "Analiza w toku",
    "jira_ready" => "Analiza gotowa",
    "jira_needs_input" => "Brakuje danych",
    "jira_handed_off" => "Komentarz w Jira",
    "jira_analysis_failed" => "Błąd analizy",
    "jira_publication_failed" => "Błąd publikacji",
    "jira_publication_unknown" => "Publikacja niepewna",
    "jira_publication_retry_wait" => "Ponawianie publikacji",
    "jira_delivery_failed" => "Błąd integracji",
    "jira_delivery_unknown" => "Niepewny wynik wysyłki",
    "jira_delivery_retry_wait" => "Ponawianie efektu",
    "jira_repair_waiting" => "Naprawa zatwierdzona",
    "repair_running" => "Naprawa w toku"
  }

  @run_labels %{
    "queued" => "W kolejce",
    "retrying" => "Ponawianie",
    "running" => "Praca agenta",
    "retry_error" => "Ponawianie po błędzie",
    "blocked" => "Zablokowany",
    "failed" => "Błąd przebiegu",
    "stopped" => "Zatrzymany",
    "human_review" => "Przegląd człowieka",
    "completed" => "Zakończony",
    "succeeded" => "Zakończony",
    "handed_off" => "Przekazany",
    "cancelled" => "Anulowany"
  }

  defp status_label(%{state: "jira_unknown", raw_status: raw}), do: raw
  defp status_label(%{state: state}) when is_map_key(@jira_labels, state), do: Map.fetch!(@jira_labels, state)

  defp status_label(%{state: state, run_status: run_status}) do
    case legacy_part(state) do
      "unknown" -> run_status
      legacy -> Map.fetch!(@run_labels, legacy)
    end
  end

  defp legacy_part("run_" <> legacy), do: legacy
  defp legacy_part("repair_" <> legacy), do: legacy

  defp attention(row) do
    case state_attention(row) do
      nil when row.paused -> %{code: "dependency_paused", message: "Połączenie jednego z efektów sprawy jest wyłączone."}
      attention -> attention
    end
  end

  defp state_attention(%{state: "jira_needs_input"}),
    do: %{code: "analysis_needs_input", message: "Do zakończenia analizy potrzebne są dodatkowe dane."}

  defp state_attention(%{state: "jira_analysis_failed"}),
    do: %{code: "analysis_failed", message: "Analiza zakończyła się błędem."}

  defp state_attention(%{state: "jira_publication_failed"}),
    do: %{code: "publication_failed", message: "Nie udało się opublikować komentarza w Jira."}

  defp state_attention(%{state: "jira_publication_unknown"}),
    do: %{code: "publication_unknown", message: "Nie wiadomo, czy komentarz trafił do Jira; sprawdź przed ponowieniem."}

  defp state_attention(%{state: "jira_publication_retry_wait"}),
    do: %{code: "publication_retry_wait", message: "Publikacja komentarza w Jira czeka na ponowienie."}

  defp state_attention(%{state: "jira_delivery_failed", failure_operation: operation}),
    do: %{code: "delivery_failed", message: "Efekt „#{operation_name(operation)}” zakończył się błędem."}

  defp state_attention(%{state: "jira_delivery_unknown", failure_operation: operation}),
    do: %{code: "delivery_unknown", message: "Nie wiadomo, czy efekt „#{operation_name(operation)}” został wykonany; sprawdź przed ponowieniem."}

  defp state_attention(%{state: "jira_delivery_retry_wait", failure_operation: operation}),
    do: %{code: "delivery_retry_wait", message: "Efekt „#{operation_name(operation)}” czeka na ponowienie."}

  defp state_attention(%{state: "jira_unknown", raw_status: raw}),
    do: %{code: "unknown_status", message: "Nieznany status sprawy: #{raw}"}

  defp state_attention(%{state: "jira_" <> _state}), do: nil

  defp state_attention(%{state: state, run_status: status, run_type: type}), do: run_attention(legacy_part(state), status, type)

  defp run_attention("failed", _status, type), do: %{code: "work_run_failed", message: "Przebieg #{type} zakończył się błędem."}
  defp run_attention("blocked", _status, type), do: %{code: "work_run_blocked", message: "Przebieg #{type} jest zablokowany."}
  defp run_attention("stopped", _status, type), do: %{code: "work_run_stopped", message: "Przebieg #{type} został zatrzymany."}

  defp run_attention("human_review", _status, type),
    do: %{code: "human_review_required", message: "Przebieg #{type} czeka na przegląd człowieka."}

  defp run_attention("retry_error", _status, type),
    do: %{code: "work_run_retry_error", message: "Przebieg #{type} ponawia pracę po błędzie."}

  defp run_attention("unknown", status, _type), do: %{code: "unknown_status", message: "Nieznany status przebiegu: #{status}"}
  defp run_attention(_legacy, _status, _type), do: nil

  defp operation_name(operation), do: Map.get(@operation_names, operation, operation)
end
