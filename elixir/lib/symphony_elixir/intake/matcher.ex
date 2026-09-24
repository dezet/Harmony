defmodule SymphonyElixir.Intake.Matcher do
  @moduledoc """
  Persists Jira match observations and atomically creates intake cases. New
  cases are announced on `intake:workspace` after the page commits.
  """

  import Ecto.Query

  alias SymphonyElixir.Intake
  alias SymphonyElixir.Jira.Issue
  alias SymphonyElixir.Repo
  alias SymphonyElixirWeb.IntakePubSub

  alias SymphonyElixir.Storage.{
    AutomationRule,
    AutomationScan,
    IntakeAnalysis,
    IntakeCase,
    IntakeEvent,
    IntegrationDelivery,
    JiraObservation
  }

  @type page_counts :: %{match_count: non_neg_integer(), accepted_count: non_neg_integer()}

  @spec matches?(AutomationRule.t(), Issue.t()) :: boolean()
  def matches?(%AutomationRule{priority_ids: priorities}, %Issue{} = issue) do
    status_category = issue.status_category

    is_binary(status_category) and String.trim(status_category) != "" and
      issue.priority_id in (priorities || []) and String.downcase(status_category) != "done"
  end

  @spec persist_page(AutomationScan.t(), [Issue.t()], keyword()) ::
          {:ok, page_counts()} | {:error, term()}
  def persist_page(%AutomationScan{} = scan, issues, opts \\ []) when is_list(issues) do
    now = current_time(opts)
    lease_token = Keyword.get(opts, :lease_token)

    case IntakePubSub.transaction(fn -> persist_page_transaction(scan, issues, now, opts, lease_token) end) do
      {:ok, counts} -> {:ok, counts}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_page_transaction(scan, issues, now, opts, lease_token) do
    with :ok <- ensure_effects_enabled(),
         %AutomationScan{} = current_scan <- lock_scan(scan.id),
         %AutomationRule{} = rule <- lock_rule(scan.rule_id),
         :ok <- validate_owner(current_scan, rule, scan, lease_token, now),
         {:ok, counts} <- persist_issues(rule, current_scan, issues, now, opts),
         :ok <- ensure_effects_enabled() do
      update_scan_counts!(current_scan, counts)
      counts
    else
      nil -> Repo.rollback(:stale_generation)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp persist_issues(rule, scan, issues, now, opts) do
    Enum.reduce_while(issues, {:ok, %{match_count: 0, accepted_count: 0}}, fn issue, result ->
      accumulate_issue(rule, scan, issue, now, opts, result)
    end)
  end

  defp accumulate_issue(rule, scan, issue, now, opts, {:ok, counts}) do
    if matches?(rule, issue) do
      case persist_issue(rule, scan, issue, now, opts) do
        {:ok, accepted?} ->
          next = %{
            match_count: counts.match_count + 1,
            accepted_count: counts.accepted_count + if(accepted?, do: 1, else: 0)
          }

          {:cont, {:ok, next}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    else
      {:cont, {:ok, counts}}
    end
  end

  defp persist_issue(rule, scan, issue, now, opts) do
    with {:ok, issue_attrs} <- issue_attrs(issue, rule, now),
         observation <- lock_observation(rule.id, issue.id),
         {:ok, observation} <- persist_observation(rule, scan, issue, observation, now),
         {:ok, status} <- maybe_accept(rule, scan, issue, issue_attrs, observation, now, opts) do
      {:ok, status == :created}
    end
  end

  defp maybe_accept(rule, scan, issue, attrs, observation, now, opts) do
    baseline_excluded? =
      observation && observation.baseline_excluded && observation.generation == rule.baseline_generation

    cond do
      scan.mode == "baseline" and rule.initial_policy == "include_existing" ->
        accept_issue(rule, issue, attrs, now, opts)

      scan.mode == "baseline" ->
        {:ok, :excluded}

      baseline_excluded? ->
        {:ok, :excluded}

      true ->
        accept_issue(rule, issue, attrs, now, opts)
    end
  end

  defp persist_observation(rule, scan, issue, nil, now) do
    attrs = %{
      jira_connection_id: rule.jira_connection_id,
      rule_id: rule.id,
      jira_issue_id: issue.id,
      first_seen_at: now,
      last_seen_at: now,
      last_priority_id: issue.priority_id,
      baseline_excluded: scan.mode == "baseline" and rule.initial_policy == "new_matches_only",
      generation: if(scan.mode == "baseline", do: scan.generation, else: nil)
    }

    %JiraObservation{}
    |> JiraObservation.changeset(attrs)
    |> Repo.insert()
    |> normalize_write()
  end

  defp persist_observation(rule, scan, issue, observation, now) do
    attrs =
      if scan.mode == "baseline" do
        %{
          last_seen_at: now,
          last_priority_id: issue.priority_id,
          baseline_excluded: rule.initial_policy == "new_matches_only",
          generation: scan.generation
        }
      else
        %{last_seen_at: now, last_priority_id: issue.priority_id}
      end

    observation
    |> JiraObservation.changeset(attrs)
    |> Repo.update()
    |> normalize_write()
  end

  defp accept_issue(rule, issue, attrs, now, opts) do
    advisory_lock!(rule.jira_connection_id, issue.id)

    case Repo.one(
           from(intake_case in IntakeCase,
             where:
               intake_case.jira_connection_id == ^rule.jira_connection_id and
                 intake_case.jira_issue_id == ^issue.id,
             lock: "FOR UPDATE"
           )
         ) do
      nil ->
        create_case(rule, issue, attrs, now, opts)

      %IntakeCase{rule_id: rule_id} = existing when rule_id == rule.id ->
        {:ok, {:already_linked, existing.id}}

      %IntakeCase{} = existing ->
        record_already_linked_once!(existing, rule, issue, now)
        {:ok, {:already_linked, existing.id}}
    end
  end

  defp create_case(rule, issue, attrs, now, opts) do
    uuid_fun = Keyword.get(opts, :uuid_fun, &Ecto.UUID.generate/0)
    profile = Keyword.fetch!(opts, :analysis_profile)
    linear_issue_id = uuid_fun.()

    case_attrs =
      attrs
      |> Map.merge(%{
        project_id: rule.project_id,
        rule_id: rule.id,
        jira_connection_id: rule.jira_connection_id,
        detected_at: now,
        linear_issue_id: linear_issue_id,
        analysis_version: 1,
        analysis_status: "queued",
        lock_version: 1
      })
      |> Intake.snapshot_case_attrs(rule, now)

    with {:ok, intake_case} <-
           %IntakeCase{}
           |> IntakeCase.changeset(case_attrs)
           |> Repo.insert(),
         {:ok, _analysis} <- insert_analysis(intake_case, profile, now),
         {:ok, _deliveries} <- insert_deliveries(intake_case, rule, issue, now),
         {:ok, _event} <- record_event(intake_case, rule, "case_detected", event_payload(issue), now),
         {:ok, _event} <- record_event(intake_case, rule, "analysis_queued", %{version: 1}, now) do
      :ok = IntakePubSub.track_case(intake_case)
      {:ok, :created}
    end
  end

  defp insert_analysis(intake_case, profile, _now) do
    input_snapshot = %{
      "case_ref" => "jira_#{intake_case.id}",
      "jira_issue_id" => intake_case.jira_issue_id,
      "jira_key" => intake_case.jira_key,
      "jira_url" => intake_case.jira_url,
      "title" => intake_case.title,
      "description_text" => intake_case.description_text,
      "priority_id" => intake_case.priority_id,
      "priority_name" => intake_case.priority_name,
      "jira_updated_at" => DateTime.to_iso8601(intake_case.jira_updated_at),
      "rule_snapshot" => intake_case.rule_snapshot
    }

    %IntakeAnalysis{}
    |> IntakeAnalysis.changeset(%{
      case_id: intake_case.id,
      version: 1,
      status: "queued",
      input_snapshot: input_snapshot,
      model: profile.model,
      effort: profile.effort
    })
    |> Repo.insert()
    |> normalize_write()
  end

  defp insert_deliveries(intake_case, rule, issue, now) do
    case_ref = "jira_#{intake_case.id}"

    deliveries =
      [
        {"linear_create", nil, "case:#{intake_case.id}:linear:v1", %{"linear_issue_id" => intake_case.linear_issue_id}},
        {"analysis", nil, "case:#{intake_case.id}:analysis:1", %{"version" => 1}}
      ] ++
        recipient_deliveries(intake_case, "email", rule.email_connection_id, rule.email_recipients) ++
        recipient_deliveries(intake_case, "sms", rule.sms_connection_id, rule.sms_recipients)

    Enum.reduce_while(deliveries, {:ok, []}, fn {operation, connection_id, key, payload}, {:ok, acc} ->
      payload = Map.merge(payload, %{"case_ref" => case_ref, "jira_key" => issue.key})

      case insert_delivery(intake_case, operation, connection_id, key, payload, now) do
        {:ok, delivery} ->
          record_event!(intake_case, rule, "delivery_queued", %{delivery_id: delivery.id, operation: operation}, now)
          {:cont, {:ok, [delivery | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, deliveries} -> {:ok, Enum.reverse(deliveries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recipient_deliveries(intake_case, operation, connection_id, recipients) do
    Enum.map(recipients || [], fn recipient ->
      recipient_hash = :crypto.hash(:sha256, recipient) |> Base.encode16(case: :lower)
      key = "case:#{intake_case.id}:#{operation}:#{recipient_hash}:detected:v1"
      {operation, connection_id, key, %{"recipient" => recipient}}
    end)
  end

  defp insert_delivery(intake_case, operation, connection_id, key, payload, now) do
    %IntegrationDelivery{}
    |> IntegrationDelivery.changeset(%{
      case_id: intake_case.id,
      connection_id: connection_id,
      operation: operation,
      dedupe_key: key,
      payload: payload,
      status: "pending",
      attempts: 0,
      next_attempt_at: now,
      lock_version: 1
    })
    |> Repo.insert()
    |> normalize_write()
  end

  defp record_already_linked_once!(intake_case, rule, issue, now) do
    exists? =
      Repo.exists?(
        from(event in IntakeEvent,
          where:
            event.case_id == ^intake_case.id and event.rule_id == ^rule.id and
              event.type == "already_linked"
        )
      )

    unless exists? do
      record_event!(intake_case, rule, "already_linked", event_payload(issue), now)
    end
  end

  defp record_event!(intake_case, rule, type, payload, now) do
    case record_event(intake_case, rule, type, payload, now) do
      {:ok, event} -> event
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp record_event(intake_case, rule, type, payload, now) do
    %IntakeEvent{}
    |> IntakeEvent.changeset(%{
      case_id: intake_case.id,
      rule_id: rule.id,
      type: type,
      payload: stringify_keys(payload),
      actor: "system",
      occurred_at: now
    })
    |> Repo.insert()
    |> normalize_write()
  end

  defp event_payload(issue) do
    %{jira_issue_id: issue.id, jira_key: issue.key}
  end

  defp issue_attrs(%Issue{} = issue, rule, now) do
    with true <- is_binary(issue.id) and issue.id != "" and is_binary(issue.key) and issue.key != "",
         true <- is_binary(issue.summary) and is_binary(issue.priority_id) and is_binary(issue.priority_name),
         {:ok, updated_at} <- parse_jira_datetime(issue.updated) do
      connection = Repo.get!(SymphonyElixir.Storage.IntegrationConnection, rule.jira_connection_id)
      site_url = setting(connection.settings, "site_url")

      if is_binary(site_url) and String.starts_with?(site_url, "https://") do
        {:ok,
         %{
           jira_issue_id: issue.id,
           jira_key: issue.key,
           jira_url: Issue.browse_url(issue, site_url),
           title: issue.summary,
           description_text: issue.description || "",
           priority_id: issue.priority_id,
           priority_name: issue.priority_name,
           jira_updated_at: updated_at,
           detected_at: now
         }}
      else
        {:error, :invalid_jira_connection}
      end
    else
      _value -> {:error, :malformed_issue}
    end
  end

  defp parse_jira_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, DateTime.truncate(datetime, :microsecond)}

      _ ->
        {:error, :malformed_issue}
    end
  end

  defp parse_jira_datetime(_value), do: {:error, :malformed_issue}

  defp setting(settings, "site_url") when is_map(settings), do: Map.get(settings, "site_url") || Map.get(settings, :site_url)
  defp setting(_settings, _key), do: nil

  defp lock_scan(id) do
    Repo.one(from(scan in AutomationScan, where: scan.id == ^id, lock: "FOR UPDATE"))
  end

  defp lock_rule(id) do
    Repo.one(from(rule in AutomationRule, where: rule.id == ^id, lock: "FOR UPDATE"))
  end

  defp lock_observation(rule_id, issue_id) do
    Repo.one(
      from(observation in JiraObservation,
        where: observation.rule_id == ^rule_id and observation.jira_issue_id == ^issue_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp validate_owner(%AutomationScan{} = current_scan, %AutomationRule{} = rule, scan, lease_token, now) do
    cond do
      not current_scan_matches?(current_scan, rule, scan) -> {:error, :stale_generation}
      not lease_matches?(rule, lease_token, now) -> {:error, :stale_generation}
      invalid_mode_owner?(scan.mode, rule) -> {:error, :stale_generation}
      true -> :ok
    end
  end

  defp current_scan_matches?(current_scan, rule, scan) do
    current_scan.status == "running" and current_scan.generation == scan.generation and
      current_scan.rule_config_version == rule.config_version
  end

  defp lease_matches?(rule, lease_token, now) do
    rule.lease_token == lease_token and not is_nil(rule.lease_until) and
      DateTime.compare(rule.lease_until, now) == :gt
  end

  defp invalid_mode_owner?("baseline", rule),
    do: rule.enabled or rule.activation_status != "activating"

  defp invalid_mode_owner?("poll", rule),
    do: not rule.enabled or is_nil(rule.baseline_generation)

  defp invalid_mode_owner?(_mode, _rule), do: false

  defp update_scan_counts!(scan, counts) do
    scan
    |> AutomationScan.changeset(%{
      match_count: scan.match_count + counts.match_count,
      accepted_count: scan.accepted_count + counts.accepted_count
    })
    |> Repo.update!()
  end

  defp advisory_lock!(connection_id, issue_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["#{connection_id}:#{issue_id}"])
  end

  defp normalize_write({:ok, value}), do: {:ok, value}
  defp normalize_write({:error, changeset}), do: {:error, changeset}

  defp ensure_effects_enabled do
    if Intake.effects_enabled?(), do: :ok, else: {:error, :effects_disabled}
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp current_time(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _ -> DateTime.utc_now()
    end
    |> DateTime.truncate(:microsecond)
  end
end
