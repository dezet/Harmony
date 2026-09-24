defmodule SymphonyElixir.Cases do
  @moduledoc """
  Read side of the Case Center (spec §11.3): the unified list of Jira intake
  cases and existing agent work, one case in detail, and its history.

  Refs are `jira_<uuid>` for an intake case and `run_<uuid>` for a work run.
  Listing, paging and counting run in PostgreSQL (`Cases.Projection`); a page
  costs a fixed number of queries whatever the number of cards.
  """

  import Ecto.Query

  alias SymphonyElixir.Cases.Projection
  alias SymphonyElixir.Intake.{Actions, CommentPublisher}
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{IntakeAnalysis, IntakeCase, IntakeEvent, IntegrationDelivery, WorkEvent, WorkRun}

  @filter_columns %{"all" => nil, "decision" => "decision", "analysis" => "analyzing", "done" => "handed_off"}

  @type position :: {DateTime.t(), String.t()} | nil
  @type list_opts :: [
          project_id: binary() | nil,
          filter: String.t(),
          column: String.t() | nil,
          q: String.t() | nil,
          limit: pos_integer(),
          after: position()
        ]

  @type list_result :: %{
          items: [map()],
          next_position: [String.t()] | nil,
          total: non_neg_integer(),
          counts: map(),
          project_counts: [map()]
        }

  @doc "Filter names of the list (`filter=`) and the Kanban columns (`column=`)."
  @spec filters() :: [String.t()]
  def filters, do: Map.keys(@filter_columns)

  @spec columns() :: [String.t()]
  def columns, do: Projection.columns()

  @doc """
  One page of case summaries. `filter` narrows to the matching column and
  combines with `column`; `counts` follow only project and search, and
  `project_counts` cover every project without any filter.
  """
  @spec list(list_opts()) :: list_result()
  def list(opts) do
    limit = Keyword.fetch!(opts, :limit)
    base = %{project_id: Keyword.get(opts, :project_id), q: Keyword.get(opts, :q)}

    case column_filter(Map.fetch!(@filter_columns, Keyword.get(opts, :filter, "all")), Keyword.get(opts, :column)) do
      :empty ->
        empty_page(base)

      {:ok, column} ->
        filters = Map.put(base, :column, column)
        rows = Projection.page(filters, limit + 1, Keyword.get(opts, :after))
        {visible, rest} = Enum.split(rows, limit)
        %{total: total, counts: counts} = Projection.counts(filters)

        %{
          items: Enum.map(visible, &Projection.summary/1),
          next_position: next_position(rest, List.last(visible)),
          total: total,
          counts: counts,
          project_counts: Projection.project_counts()
        }
    end
  end

  @doc """
  Case detail. For a Jira case: summary with case fields, the analysis of the
  current version (nil before a result), deliveries, publication and actions
  computed by `Intake.Actions`. For agent work: summary with the work run.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def fetch(ref, opts \\ []) do
    with {:ok, parsed} <- parse_ref(ref),
         row when is_map(row) <- Projection.fetch(parsed) do
      {:ok, detail(parsed, Projection.summary(row), opts)}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc """
  History of a case in occurrence order: intake events for a Jira case, work
  events for agent work. Delivery events carry the operation and the masked
  recipient of their delivery; recipients never leave this module unmasked
  (spec §12).
  """
  @spec events(String.t(), limit: pos_integer(), after: position()) ::
          {:ok, %{items: [map()], next_position: [String.t()] | nil}} | {:error, :not_found}
  def events(ref, opts) do
    limit = Keyword.fetch!(opts, :limit)

    with {:ok, parsed} <- parse_ref(ref),
         true <- exists?(parsed) do
      rows = event_rows(parsed, limit + 1, Keyword.get(opts, :after))
      {visible, rest} = Enum.split(rows, limit)
      next = next_position(rest, List.last(visible), :occurred_at, :id)
      {:ok, %{items: Enum.map(visible, &mask_event/1), next_position: next}}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc "Masks an e-mail address or phone number for history views."
  @spec mask_recipient(String.t()) :: String.t()
  def mask_recipient(recipient) when is_binary(recipient) do
    case String.split(recipient, "@", parts: 2) do
      [local, domain] when local != "" -> String.first(local) <> "***@" <> domain
      _phone_or_other -> mask_middle(recipient)
    end
  end

  defp mask_middle(value) do
    length = String.length(value)

    if length > 6,
      do: String.slice(value, 0, 3) <> String.duplicate("*", length - 6) <> String.slice(value, -3, 3),
      else: "***"
  end

  @doc "Parses `jira_<uuid>` and `run_<uuid>` refs."
  @spec parse_ref(term()) :: {:ok, {:jira | :run, binary()}} | {:error, :not_found}
  def parse_ref("jira_" <> id), do: cast_ref(:jira, id)
  def parse_ref("run_" <> id), do: cast_ref(:run, id)
  def parse_ref(_ref), do: {:error, :not_found}

  defp cast_ref(kind, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} when uuid == id -> {:ok, {kind, uuid}}
      _invalid -> {:error, :not_found}
    end
  end

  defp column_filter(nil, column), do: {:ok, column}
  defp column_filter(filter_column, nil), do: {:ok, filter_column}
  defp column_filter(same, same), do: {:ok, same}
  defp column_filter(_filter_column, _column), do: :empty

  defp empty_page(base) do
    %{total: _total, counts: counts} = Projection.counts(Map.put(base, :column, nil))
    %{items: [], next_position: nil, total: 0, counts: counts, project_counts: Projection.project_counts()}
  end

  defp next_position(rest, last, date_key \\ :detected_at, id_key \\ :ref)
  defp next_position([_ | _], %{} = last, date_key, id_key), do: [DateTime.to_iso8601(Map.fetch!(last, date_key)), Map.fetch!(last, id_key)]
  defp next_position(_rest, _last, _date_key, _id_key), do: nil

  # ── detail ────────────────────────────────────────────────────────────────

  defp detail({:jira, id}, summary, opts) do
    intake_case = Repo.get!(IntakeCase, id)
    analysis = Repo.get_by(IntakeAnalysis, case_id: id, version: intake_case.analysis_version)

    deliveries =
      Repo.all(from(delivery in IntegrationDelivery, where: delivery.case_id == ^id, order_by: [asc: delivery.inserted_at, asc: delivery.id]))

    %{
      case: Map.merge(summary, case_fields(intake_case)),
      analysis: analysis_result(analysis),
      links: %{jira: summary.jira, linear: summary.linear},
      deliveries: deliveries,
      actions: Actions.availability(intake_case, opts),
      publication: publication(intake_case, deliveries),
      version: intake_case.lock_version
    }
  end

  defp detail({:run, id}, summary, _opts) do
    work_run = Repo.get!(WorkRun, id)
    unsupported = %{allowed: false, reason: "unsupported_case_kind"}

    %{
      case: Map.merge(summary, %{project_id: work_run.project_id, work_run: work_run_fields(work_run)}),
      analysis: nil,
      links: %{jira: nil, linear: summary.linear},
      deliveries: [],
      actions: %{acknowledge: unsupported, reanalyze: unsupported, approve_repair: unsupported},
      publication: nil,
      version: nil
    }
  end

  defp case_fields(%IntakeCase{} = intake_case) do
    intake_case
    |> Map.take([
      :project_id,
      :rule_id,
      :jira_connection_id,
      :jira_issue_id,
      :description_text,
      :jira_updated_at,
      :linear_state_name,
      :analysis_version,
      :analysis_status,
      :acknowledged_at,
      :repair_approved_at,
      :repair_approved_version
    ])
    |> Map.put(:rule_snapshot, rule_snapshot(intake_case.rule_snapshot || %{}))
  end

  # The stored snapshot also holds alert recipients; the detail exposes only
  # the rule identity (spec §12 keeps full recipient lists in the rule form).
  defp rule_snapshot(snapshot) do
    Map.new(~w(name source_type source_id priority_ids initial_policy qualified_at), &{&1, Map.get(snapshot, &1)})
  end

  defp analysis_result(%IntakeAnalysis{status: status} = analysis) when status in ["succeeded", "failed", "needs_input"] do
    snapshot = analysis.input_snapshot || %{}

    analysis
    |> Map.take([:version, :status, :result, :model, :effort, :started_at, :completed_at, :token_usage, :error_code, :work_run_id])
    |> Map.put(:input_snapshot, %{
      context_scope: Map.get(snapshot, "context_scope") || get_in(analysis.result || %{}, ["context_scope"]),
      jira_key: Map.get(snapshot, "jira_key"),
      repo_sha: Map.get(snapshot, "repository_sha")
    })
  end

  defp analysis_result(_queued_running_or_missing), do: nil

  defp publication(%IntakeCase{id: id, analysis_version: version}, deliveries) do
    dedupe_key = "case:#{id}:jira-comment:#{version}"
    comment = Enum.find(deliveries, &(&1.operation == "jira_comment" and &1.dedupe_key == dedupe_key))

    %{
      status: publication_status(comment),
      version: version,
      comment_id: if(publication_status(comment) == "published", do: comment.provider_id),
      marker: CommentPublisher.marker(id, version),
      published_at: comment && comment.sent_at,
      error_code: comment && comment.last_error_code
    }
  end

  defp publication_status(%IntegrationDelivery{status: "succeeded", provider_id: provider_id, sent_at: %DateTime{}})
       when is_binary(provider_id) and provider_id != "",
       do: "published"

  defp publication_status(%IntegrationDelivery{status: status}) when status in ["failed", "unknown"], do: status
  defp publication_status(_pending_or_missing), do: "pending"

  defp work_run_fields(%WorkRun{} = work_run) do
    %{
      id: work_run.id,
      type: work_run.type,
      status: work_run.status,
      agent_backend: work_run.agent_backend,
      forge: forge(work_run)
    }
  end

  defp forge(%WorkRun{forge_owner: nil, forge_repo: nil}), do: nil

  defp forge(%WorkRun{} = work_run) do
    %{
      owner: work_run.forge_owner,
      repo: work_run.forge_repo,
      pr_number: work_run.forge_pr_number,
      head_ref: work_run.forge_head_ref,
      base_ref: work_run.forge_base_ref
    }
  end

  # ── history ───────────────────────────────────────────────────────────────

  defp exists?({:jira, id}), do: Repo.exists?(from(intake_case in IntakeCase, where: intake_case.id == ^id))
  defp exists?({:run, id}), do: Repo.exists?(from(work_run in WorkRun, where: work_run.id == ^id))

  defp event_rows({:jira, id}, limit, position) do
    from(event in IntakeEvent,
      left_join: delivery in IntegrationDelivery,
      on: delivery.case_id == event.case_id and fragment("?::text = ?->>'delivery_id'", delivery.id, event.payload),
      where: event.case_id == ^id,
      order_by: [asc: event.occurred_at, asc: event.id],
      limit: ^limit,
      select: %{
        id: event.id,
        type: event.type,
        actor: event.actor,
        occurred_at: event.occurred_at,
        payload: event.payload,
        operation: delivery.operation,
        recipient: fragment("?->>'recipient'", delivery.payload)
      }
    )
    |> after_event(position)
    |> Repo.all()
  end

  defp event_rows({:run, id}, limit, position) do
    from(event in WorkEvent,
      where: event.work_run_id == ^id,
      order_by: [asc: event.inserted_at, asc: event.id],
      limit: ^limit,
      select: %{
        id: event.id,
        type: event.type,
        actor: "system",
        occurred_at: event.inserted_at,
        payload: event.payload,
        operation: nil,
        recipient: nil
      }
    )
    |> after_work_event(position)
    |> Repo.all()
  end

  @recipient_keys ~w(recipient recipients email_recipients sms_recipients)

  defp mask_event(event) do
    %{
      event
      | recipient: event.recipient && mask_recipient(event.recipient),
        payload: Map.new(event.payload || %{}, &mask_payload_entry/1)
    }
  end

  defp mask_payload_entry({key, value}) when key in @recipient_keys, do: {key, mask_value(value)}
  defp mask_payload_entry(entry), do: entry

  defp mask_value(value) when is_binary(value), do: mask_recipient(value)
  defp mask_value(values) when is_list(values), do: Enum.map(values, &mask_value/1)
  defp mask_value(_value), do: "***"

  defp after_event(query, nil), do: query

  defp after_event(query, {occurred_at, id}) do
    where(query, [event], event.occurred_at > ^occurred_at or (event.occurred_at == ^occurred_at and event.id > ^id))
  end

  defp after_work_event(query, nil), do: query

  defp after_work_event(query, {inserted_at, id}) do
    where(query, [event], event.inserted_at > ^inserted_at or (event.inserted_at == ^inserted_at and event.id > ^id))
  end
end
