defmodule SymphonyElixirWeb.IntakePubSub do
  @moduledoc """
  Realtime invalidation for the Case Center (spec §11.4).

  Topic `intake:workspace` carries one event, `changed`, whose payload is always
  exactly `project_id`, `case_ref`, `rule_id`, `revision` and `changed_at`.
  Identifiers that are absent or not UUID-shaped are `nil`; titles, descriptions,
  recipients, secrets and analysis never reach the topic. Clients refetch the
  details over REST.

  An event must describe committed data. Writers therefore either call
  `broadcast_changed/1` (or a `*_changed` helper) after their transaction has
  returned, or run the transaction through `transaction/2` and `track/1` the
  change inside it: tracked changes are broadcast after the outermost commit and
  discarded on rollback or crash. A notification from inside a transaction that
  `transaction/2` does not own is dropped and logged, never sent early.
  """

  import Ecto.Query

  require Logger

  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{AutomationRule, IntakeCase, IntegrationDelivery, WorkRun}

  @pubsub SymphonyElixir.PubSub
  @topic "intake:workspace"
  # Phoenix already subscribes a joined channel process to its own topic, so the
  # server-side messages use a separate topic; otherwise each event would be
  # delivered to the channel twice.
  @server_topic "intake:workspace:changes"
  @pending_key {__MODULE__, :pending}
  @case_ref ~r/\A(jira|run)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @type payload :: %{
          project_id: String.t() | nil,
          case_ref: String.t() | nil,
          rule_id: String.t() | nil,
          revision: pos_integer(),
          changed_at: String.t()
        }

  @type change :: %{optional(:project_id) => term(), optional(:case_ref) => term(), optional(:rule_id) => term()}

  @doc "Client-facing channel topic."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the caller to `{:intake_changed, payload}` messages."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @server_topic)

  @doc """
  Runs `fun` in a `Repo` transaction and broadcasts the changes tracked inside
  it once the outermost transaction has committed. Returns what the repo's
  `transaction/1` returns.
  """
  @spec transaction((-> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def transaction(fun, opts \\ []) when is_function(fun, 0) do
    repo = Keyword.get(opts, :repo, Repo)

    if tracking?() or repo.in_transaction?() do
      repo.transaction(fun)
    else
      run_tracked(repo, fun)
    end
  end

  defp run_tracked(repo, fun) do
    Process.put(@pending_key, [])

    try do
      result = repo.transaction(fun)
      pending = Process.delete(@pending_key) || []
      if match?({:ok, _value}, result), do: flush(pending)
      result
    after
      Process.delete(@pending_key)
    end
  end

  @doc "Records a change for the enclosing `transaction/2`, or broadcasts it now outside a transaction."
  @spec track(change()) :: :ok
  def track(change) when is_map(change), do: enqueue({:change, change})

  @doc "Tracks a change of one intake case; the case id alone is resolved to its project after commit."
  @spec track_case(IntakeCase.t() | binary() | nil) :: :ok
  def track_case(nil), do: :ok
  def track_case(%IntakeCase{} = intake_case), do: track(case_change(intake_case))
  def track_case(case_id) when is_binary(case_id), do: enqueue({:case, case_id})

  @spec track_rule(AutomationRule.t()) :: :ok
  def track_rule(%AutomationRule{id: id, project_id: project_id}), do: track(%{project_id: project_id, rule_id: id})

  @doc "A change of workspace configuration (integration connections), not bound to a project."
  @spec track_config() :: :ok
  def track_config, do: track(%{})

  @spec delivery_changed(IntegrationDelivery.t()) :: :ok
  def delivery_changed(%IntegrationDelivery{case_id: case_id}), do: track_case(case_id)

  @spec run_changed(WorkRun.t()) :: :ok
  def run_changed(%WorkRun{id: id, project_id: project_id}), do: track(%{project_id: project_id, case_ref: "run_" <> to_string(id)})

  @doc "Broadcasts one change now; dropped with a log line when called inside an open transaction."
  @spec broadcast_changed(change()) :: :ok
  def broadcast_changed(change) when is_map(change) do
    if safe_in_transaction?() do
      Logger.warning("intake change notification skipped inside an open transaction outcome=skipped")
      :ok
    else
      publish(change)
    end
  end

  @doc "Builds the whitelisted `changed` payload."
  @spec payload(change()) :: payload()
  def payload(change) when is_map(change) do
    %{
      project_id: uuid(Map.get(change, :project_id)),
      case_ref: case_ref(Map.get(change, :case_ref)),
      rule_id: uuid(Map.get(change, :rule_id)),
      revision: System.unique_integer([:positive, :monotonic]),
      changed_at: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    }
  end

  defp enqueue(item) do
    case Process.get(@pending_key) do
      pending when is_list(pending) ->
        Process.put(@pending_key, [item | pending])
        :ok

      nil ->
        if safe_in_transaction?() do
          Logger.warning("intake change notification skipped inside an open transaction outcome=skipped")
          :ok
        else
          flush([item])
        end
    end
  end

  defp flush([]), do: :ok

  defp flush(pending) do
    pending
    |> Enum.reverse()
    |> resolve_cases()
    |> Enum.uniq()
    |> Enum.each(&publish/1)
  end

  defp resolve_cases(items) do
    case_ids = for {:case, id} <- items, uniq: true, do: id
    cases = load_cases(case_ids)

    Enum.flat_map(items, fn
      {:change, change} -> [change]
      {:case, id} -> cases |> Map.get(id) |> List.wrap()
    end)
  end

  defp load_cases([]), do: %{}

  defp load_cases(case_ids) do
    from(intake_case in IntakeCase,
      where: intake_case.id in ^case_ids,
      select: {intake_case.id, intake_case.project_id, intake_case.rule_id}
    )
    |> Repo.all()
    |> Map.new(fn {id, project_id, rule_id} -> {id, %{project_id: project_id, case_ref: "jira_" <> id, rule_id: rule_id}} end)
  rescue
    exception ->
      # The write already committed; a failed lookup only costs this notification.
      Logger.warning("intake change notification lookup failed outcome=skipped reason=#{inspect(exception.__struct__)}")
      %{}
  end

  defp case_change(%IntakeCase{id: id, project_id: project_id, rule_id: rule_id}),
    do: %{project_id: project_id, case_ref: "jira_" <> to_string(id), rule_id: rule_id}

  defp publish(change) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, @server_topic, {:intake_changed, payload(change)})
        :ok

      _missing ->
        :ok
    end
  end

  defp tracking?, do: is_list(Process.get(@pending_key))

  defp safe_in_transaction? do
    Repo.in_transaction?()
  rescue
    _exception -> false
  end

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid(_value), do: nil

  defp case_ref(value) when is_binary(value), do: if(Regex.match?(@case_ref, value), do: value, else: nil)
  defp case_ref(_value), do: nil
end
