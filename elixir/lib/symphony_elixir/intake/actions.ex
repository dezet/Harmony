defmodule SymphonyElixir.Intake.Actions do
  @moduledoc "Transactional operator actions for Jira intake cases."

  import Ecto.Query

  require Logger

  alias SymphonyElixir.Intake
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.IntakeAnalysis
  alias SymphonyElixir.Storage.IntakeCase
  alias SymphonyElixir.Storage.IntakeEvent
  alias SymphonyElixir.Storage.IntegrationDelivery

  @type action_error ::
          :analysis_not_published
          | :analysis_not_ready
          | :analysis_profile_unavailable
          | :confirmation_required
          | :invalid_action
          | :linear_not_confirmed
          | :not_found
          | :repair_already_approved
          | :stale_version

  @type action_result :: {:ok, IntakeCase.t()} | {:error, action_error() | term()}

  @spec acknowledge(String.t(), pos_integer()) :: action_result()
  def acknowledge(case_id, expected_version), do: acknowledge(case_id, expected_version, [])

  @spec acknowledge(String.t(), pos_integer(), keyword()) :: action_result()
  def acknowledge(case_id, expected_version, opts)
      when is_binary(case_id) and is_integer(expected_version) and expected_version > 0 and is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    now = current_time(opts)

    transact(repo, fn -> acknowledge_in_transaction(repo, case_id, expected_version, now) end)
  end

  def acknowledge(_case_id, _expected_version, _opts), do: {:error, :invalid_action}

  @spec approve_repair(String.t(), pos_integer(), pos_integer(), boolean()) :: action_result()
  def approve_repair(case_id, expected_version, analysis_version, confirmed?) do
    approve_repair(case_id, expected_version, analysis_version, confirmed?, [])
  end

  @spec approve_repair(String.t(), pos_integer(), pos_integer(), boolean(), keyword()) :: action_result()
  def approve_repair(case_id, expected_version, analysis_version, confirmed?, opts)
      when is_binary(case_id) and is_integer(expected_version) and expected_version > 0 and
             is_integer(analysis_version) and analysis_version > 0 and is_boolean(confirmed?) and is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    now = current_time(opts)

    repo
    |> transact(fn ->
      approve_in_transaction(repo, case_id, expected_version, analysis_version, confirmed?, now)
    end)
    |> finish_approval(opts)
  end

  def approve_repair(_case_id, _expected_version, _analysis_version, _confirmed?, _opts),
    do: {:error, :invalid_action}

  @spec reanalyze(String.t(), pos_integer(), boolean()) :: action_result()
  def reanalyze(case_id, expected_version, confirmed?), do: reanalyze(case_id, expected_version, confirmed?, [])

  @spec reanalyze(String.t(), pos_integer(), boolean(), keyword()) :: action_result()
  def reanalyze(case_id, expected_version, confirmed?, opts)
      when is_binary(case_id) and is_integer(expected_version) and expected_version > 0 and
             is_boolean(confirmed?) and is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    now = current_time(opts)

    transact(repo, fn ->
      with %IntakeCase{} = intake_case <- lock_case(repo, case_id),
           :ok <- current_lock_version(intake_case, expected_version),
           :ok <- require_confirmation(confirmed?),
           :ok <- approval_absent(intake_case),
           {:ok, profile} <- analysis_profile(opts) do
        queue_reanalysis(repo, intake_case, profile, now)
      else
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  def reanalyze(_case_id, _expected_version, _confirmed?, _opts), do: {:error, :invalid_action}

  defp acknowledge_in_transaction(repo, case_id, expected_version, now) do
    case lock_case(repo, case_id) do
      %IntakeCase{} = intake_case -> acknowledge_current_case(repo, intake_case, expected_version, now)
      nil -> {:error, :not_found}
    end
  end

  defp acknowledge_current_case(repo, intake_case, expected_version, now) do
    case current_lock_version(intake_case, expected_version) do
      :ok -> persist_acknowledgement(repo, intake_case, now)
      {:error, _reason} = error -> error
    end
  end

  defp persist_acknowledgement(_repo, %IntakeCase{acknowledged_at: acknowledged_at} = intake_case, _now)
       when not is_nil(acknowledged_at),
       do: {:ok, intake_case}

  defp persist_acknowledgement(repo, intake_case, now) do
    acknowledged =
      intake_case
      |> IntakeCase.changeset(%{
        acknowledged_at: now,
        lock_version: intake_case.lock_version + 1
      })
      |> repo.update!()

    record_event!(repo, acknowledged, "case_acknowledged", %{analysis_version: acknowledged.analysis_version}, now)
    {:ok, acknowledged}
  end

  defp approve_in_transaction(repo, case_id, expected_version, analysis_version, confirmed?, now) do
    case lock_case(repo, case_id) do
      %IntakeCase{} = intake_case ->
        approval_decision(repo, intake_case, expected_version, analysis_version, confirmed?, now)

      nil ->
        {:error, :not_found}
    end
  end

  defp finish_approval({:approved, %IntakeCase{} = intake_case}, opts) do
    request_refresh(opts, intake_case)
    {:ok, intake_case}
  end

  defp finish_approval({:already_approved, %IntakeCase{} = intake_case}, _opts), do: {:ok, intake_case}
  defp finish_approval({:error, _reason} = error, _opts), do: error
  defp finish_approval(_result, _opts), do: {:error, :action_unavailable}

  defp approval_decision(repo, intake_case, expected_version, analysis_version, confirmed?, now) do
    cond do
      analysis_version != intake_case.analysis_version ->
        {:error, :stale_version}

      approved_for_version?(intake_case, analysis_version) ->
        {:already_approved, intake_case}

      true ->
        approve_current_version(repo, intake_case, expected_version, analysis_version, confirmed?, now)
    end
  end

  defp approve_current_version(repo, intake_case, expected_version, analysis_version, confirmed?, now) do
    with :ok <- current_lock_version(intake_case, expected_version),
         :ok <- require_confirmation(confirmed?),
         :ok <- approval_absent(intake_case),
         :ok <- require_ready_analysis(repo, intake_case, analysis_version),
         :ok <- require_confirmed_linear(intake_case),
         :ok <- require_published_comment(repo, intake_case.id, analysis_version) do
      persist_approval(repo, intake_case, analysis_version, now)
    end
  end

  defp require_ready_analysis(repo, %IntakeCase{} = intake_case, version) do
    if intake_case.analysis_status == "ready" and current_analysis_ready?(repo, intake_case.id, version) do
      :ok
    else
      {:error, :analysis_not_ready}
    end
  end

  defp require_confirmed_linear(%IntakeCase{} = intake_case) do
    if not is_nil(intake_case.linear_confirmed_at) and confirmed_linear_link?(intake_case) do
      :ok
    else
      {:error, :linear_not_confirmed}
    end
  end

  defp require_published_comment(repo, case_id, version) do
    if comment_published?(repo, case_id, version), do: :ok, else: {:error, :analysis_not_published}
  end

  defp persist_approval(repo, intake_case, analysis_version, now) do
    approved =
      intake_case
      |> IntakeCase.changeset(%{
        repair_approved_at: now,
        repair_approved_version: analysis_version,
        lock_version: intake_case.lock_version + 1
      })
      |> repo.update!()

    record_event!(repo, approved, "repair_approved", %{analysis_version: analysis_version}, now)
    {:approved, approved}
  end

  defp queue_reanalysis(repo, intake_case, profile, now) do
    version = intake_case.analysis_version + 1

    updated_case =
      intake_case
      |> IntakeCase.changeset(%{
        analysis_version: version,
        analysis_status: "queued",
        acknowledged_at: nil,
        lock_version: intake_case.lock_version + 1
      })
      |> repo.update!()

    %IntakeAnalysis{}
    |> IntakeAnalysis.changeset(%{
      case_id: intake_case.id,
      version: version,
      status: "queued",
      input_snapshot: analysis_input_snapshot(updated_case, version, now),
      model: profile.model,
      effort: profile.effort
    })
    |> repo.insert!()

    %IntegrationDelivery{}
    |> IntegrationDelivery.changeset(%{
      case_id: intake_case.id,
      operation: "analysis",
      dedupe_key: "case:#{intake_case.id}:analysis:#{version}",
      payload: %{
        "version" => version,
        "case_ref" => "jira_#{intake_case.id}",
        "jira_key" => intake_case.jira_key
      },
      status: "pending",
      attempts: 0,
      next_attempt_at: now,
      lock_version: 1
    })
    |> repo.insert!()

    record_event!(repo, updated_case, "analysis_reanalyze_requested", %{version: version}, now)
    record_event!(repo, updated_case, "delivery_queued", %{operation: "analysis", version: version}, now)

    {:ok, updated_case}
  end

  defp analysis_profile(opts) do
    case Keyword.fetch(opts, :analysis_profile) do
      {:ok, profile} ->
        normalize_analysis_profile(profile)

      :error ->
        Intake.analysis_profile()
    end
  end

  defp normalize_analysis_profile(%{model: model, effort: effort})
       when is_binary(model) and is_binary(effort) do
    model = String.trim(model)
    effort = String.trim(effort)

    if model != "" and effort != "" do
      {:ok, %{model: model, effort: effort}}
    else
      {:error, :analysis_profile_unavailable}
    end
  end

  defp normalize_analysis_profile(_invalid_profile), do: {:error, :analysis_profile_unavailable}

  defp analysis_input_snapshot(intake_case, version, now) do
    %{
      "case_ref" => "jira_#{intake_case.id}",
      "jira_issue_id" => intake_case.jira_issue_id,
      "jira_key" => intake_case.jira_key,
      "jira_url" => intake_case.jira_url,
      "title" => intake_case.title,
      "description_text" => intake_case.description_text,
      "priority_id" => intake_case.priority_id,
      "priority_name" => intake_case.priority_name,
      "jira_updated_at" => DateTime.to_iso8601(intake_case.jira_updated_at),
      "rule_snapshot" => intake_case.rule_snapshot,
      "analysis_version" => version,
      "requested_at" => DateTime.to_iso8601(now)
    }
  end

  defp current_analysis_ready?(repo, case_id, version) do
    case repo.get_by(IntakeAnalysis, case_id: case_id, version: version) do
      %IntakeAnalysis{status: "succeeded", result: result} when is_map(result) -> true
      _other -> false
    end
  end

  defp comment_published?(repo, case_id, version) do
    dedupe_key = "case:#{case_id}:jira-comment:#{version}"

    case repo.get_by(IntegrationDelivery,
           case_id: case_id,
           operation: "jira_comment",
           dedupe_key: dedupe_key
         ) do
      %IntegrationDelivery{status: "succeeded", provider_id: provider_id, sent_at: %DateTime{}}
      when is_binary(provider_id) and provider_id != "" ->
        true

      _other ->
        false
    end
  end

  defp confirmed_linear_link?(%IntakeCase{linear_identifier: identifier, linear_url: url}) do
    is_binary(identifier) and identifier != "" and is_binary(url) and url != ""
  end

  defp approved_for_version?(%IntakeCase{} = intake_case, version) do
    not is_nil(intake_case.repair_approved_at) and intake_case.repair_approved_version == version
  end

  defp approval_absent(%IntakeCase{repair_approved_at: nil, repair_approved_version: nil}), do: :ok
  defp approval_absent(_intake_case), do: {:error, :repair_already_approved}

  defp require_confirmation(true), do: :ok
  defp require_confirmation(false), do: {:error, :confirmation_required}

  defp current_lock_version(%IntakeCase{lock_version: version}, version), do: :ok
  defp current_lock_version(_intake_case, _expected_version), do: {:error, :stale_version}

  defp lock_case(repo, case_id) do
    repo.one(from(intake_case in IntakeCase, where: intake_case.id == ^case_id, lock: "FOR UPDATE"))
  end

  defp record_event!(repo, %IntakeCase{} = intake_case, type, payload, now) do
    %IntakeEvent{}
    |> IntakeEvent.changeset(%{
      case_id: intake_case.id,
      rule_id: intake_case.rule_id,
      type: type,
      payload: payload,
      actor: "operator",
      occurred_at: now
    })
    |> repo.insert!()
  end

  defp transact(repo, fun) do
    case repo.transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  rescue
    _exception -> {:error, :action_unavailable}
  catch
    _kind, _reason -> {:error, :action_unavailable}
  end

  defp normalize_error(%Ecto.Changeset{}), do: :action_unavailable
  defp normalize_error(reason), do: reason

  defp request_refresh(opts, %IntakeCase{id: case_id, linear_issue_id: issue_id, linear_identifier: identifier}) do
    refresh_fun = Keyword.get(opts, :refresh_fun, &Orchestrator.request_refresh/0)

    case refresh_fun.() do
      :unavailable ->
        log_refresh_failure(case_id, issue_id, identifier, :orchestrator_unavailable)

      {:error, _reason} ->
        log_refresh_failure(case_id, issue_id, identifier, :refresh_error)

      _result ->
        :ok
    end
  rescue
    exception ->
      log_refresh_failure(case_id, issue_id, identifier, exception.__struct__)
      :ok
  catch
    _kind, _reason ->
      log_refresh_failure(case_id, issue_id, identifier, :refresh_failed)
      :ok
  end

  defp log_refresh_failure(case_id, issue_id, identifier, reason) do
    Logger.warning("Intake approval committed but orchestrator refresh failed issue_id=#{issue_id} issue_identifier=#{identifier} case_id=#{case_id} outcome=failed reason=#{inspect(reason)}")
  end

  defp current_time(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _other -> DateTime.utc_now()
    end
    |> DateTime.truncate(:microsecond)
  end
end
