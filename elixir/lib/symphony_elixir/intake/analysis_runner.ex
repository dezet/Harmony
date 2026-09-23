defmodule SymphonyElixir.Intake.AnalysisRunner do
  @moduledoc "Runs one isolated, read-only analysis turn and atomically stores its result and comment delivery."

  import Ecto.Query

  alias SymphonyElixir.AgentBackends.Codex
  alias SymphonyElixir.Config
  alias SymphonyElixir.Intake.{AnalysisContext, AnalysisPrompt, AnalysisResult}
  alias SymphonyElixir.Repo

  alias SymphonyElixir.Storage.{
    IntakeAnalysis,
    IntakeCase,
    IntakeEvent,
    IntegrationDelivery,
    Project,
    WorkRun
  }

  @max_model_starts 2

  @spec perform(IntegrationDelivery.t()) :: term()
  def perform(delivery), do: perform(delivery, [])

  @spec perform(IntegrationDelivery.t(), keyword()) :: term()
  def perform(%IntegrationDelivery{operation: "analysis", case_id: case_id} = delivery, opts)
      when is_binary(case_id) and is_list(opts) do
    started_ms = monotonic_time(opts)

    with {:ok, attempt} <- begin_attempt(delivery, opts) do
      root = workspace_root(opts)
      version = attempt.version

      outcome =
        try do
          run_attempt(attempt, root, started_ms, opts)
        rescue
          _exception -> {:error, :analysis_failed}
        catch
          :exit, _reason -> {:error, :analysis_failed}
        end

      outcome =
        case cleanup_snapshot(root, case_id, version, opts) do
          :ok -> outcome
          {:error, _reason} -> {:error, :analysis_snapshot_cleanup_failed}
        end

      finish_attempt(delivery, attempt, outcome, opts)
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  rescue
    _exception -> {:retry, "analysis_local_state_unavailable", nil}
  catch
    :exit, _reason -> {:retry, "analysis_local_state_unavailable", nil}
  end

  def perform(%IntegrationDelivery{}, _opts), do: {:error, "invalid_analysis_delivery"}

  defp begin_attempt(%IntegrationDelivery{attempts: attempts} = delivery, opts)
       when attempts <= @max_model_starts do
    now = current_time(opts)

    Repo.transaction(fn ->
      with {:ok, leased_delivery} <- leased_delivery(delivery, now),
           %IntakeCase{} = intake_case <- lock_case(delivery.case_id),
           true <- intake_case.linear_confirmed_at != nil,
           version when is_integer(version) <- payload_version(delivery.payload),
           true <- intake_case.analysis_version == version,
           %IntakeAnalysis{} = analysis <- lock_analysis(intake_case.id, version),
           %Project{} = project <- Repo.get(Project, intake_case.project_id) do
        start_work_run(leased_delivery, intake_case, analysis, project, version, now)
      else
        false -> {:error, :unconfirmed_linear_or_stale_version}
        nil -> {:error, :analysis_context_not_found}
        {:error, reason} -> {:error, reason}
        _other -> {:error, :invalid_analysis_delivery}
      end
    end)
    |> transaction_result()
  end

  defp begin_attempt(%IntegrationDelivery{}, _opts), do: {:error, :analysis_attempt_limit_reached}

  defp start_work_run(delivery, intake_case, analysis, project, version, now) do
    attempt = delivery.attempts
    dedupe_key = "intake:#{intake_case.id}:jira_analysis:v#{version}:attempt#{attempt}"

    case Repo.get_by(WorkRun, project_id: project.id, dedupe_key: dedupe_key) do
      %WorkRun{} ->
        {:error, :analysis_attempt_already_started}

      nil ->
        work_run =
          %WorkRun{}
          |> WorkRun.changeset(%{
            project_id: project.id,
            type: "jira_analysis",
            status: "running",
            dedupe_key: dedupe_key,
            linear_issue_id: intake_case.linear_issue_id,
            linear_identifier: intake_case.linear_identifier,
            linear_url: intake_case.linear_url,
            agent_backend: "codex",
            payload: %{
              "case_id" => intake_case.id,
              "analysis_version" => version,
              "delivery_id" => delivery.id,
              "attempt" => attempt
            }
          })
          |> Repo.insert!()

        analysis
        |> IntakeAnalysis.changeset(%{
          work_run_id: work_run.id,
          model: analysis.model,
          effort: analysis.effort,
          started_at: now,
          completed_at: nil,
          error_code: nil
        })
        |> Repo.update!()

        record_event!(intake_case, "analysis_work_run_started", %{version: version, work_run_id: work_run.id}, now)

        {:ok,
         %{
           delivery: delivery,
           intake_case: intake_case,
           analysis: analysis,
           project: project,
           version: version,
           work_run: work_run
         }}
    end
  end

  defp run_attempt(attempt, workspace_root, started_ms, opts) do
    with {:ok, context} <- prepare_context(workspace_root, attempt, opts),
         input_snapshot = Map.merge(attempt.analysis.input_snapshot || %{}, context.input_snapshot || %{}),
         :ok <- persist_input_snapshot(attempt, input_snapshot, opts),
         deadline_ms = started_ms + timeout_ms(opts),
         true <- remaining_ms(deadline_ms, opts) > 0,
         {prompt, issue} <- AnalysisPrompt.build(attempt.intake_case, input_snapshot, context.path),
         {:ok, model_response, captured} <-
           call_model(context.path, prompt, issue, attempt.analysis, attempt.delivery, deadline_ms, opts),
         {:ok, raw_result} <- model_output(model_response, captured),
         {:ok, result} <-
           AnalysisResult.validate(raw_result, %{
             jira_key: attempt.intake_case.jira_key,
             context_scope: Map.get(input_snapshot, "context_scope"),
             snapshot_path: context.path
           }),
         true <- remaining_ms(deadline_ms, opts) > 0 do
      usage = model_usage(model_response, captured)

      {:ok,
       %{
         input_snapshot: input_snapshot,
         result: result,
         token_usage: usage,
         model: response_value(model_response, :model) || attempt.analysis.model,
         effort: response_value(model_response, :effort) || attempt.analysis.effort
       }}
    else
      false -> {:error, :analysis_timeout}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_analysis_response}
    end
  end

  defp prepare_context(workspace_root, attempt, opts) do
    case Keyword.get(opts, :context_fun) do
      fun when is_function(fun, 4) ->
        normalize_context(fun.(workspace_root, attempt.intake_case.id, attempt.version, attempt.project))

      _default ->
        context_opts = Keyword.get(opts, :context_opts, [])

        AnalysisContext.prepare(
          workspace_root,
          attempt.intake_case.id,
          attempt.version,
          attempt.project,
          context_opts
        )
    end
  rescue
    _exception -> {:error, :analysis_context_failed}
  end

  defp normalize_context({:ok, %{path: path, input_snapshot: snapshot} = context})
       when is_binary(path) and is_map(snapshot), do: {:ok, context}

  defp normalize_context({:error, _reason} = error), do: error
  defp normalize_context(_other), do: {:error, :analysis_context_failed}

  defp persist_input_snapshot(attempt, input_snapshot, opts) do
    now = current_time(opts)

    Repo.transaction(fn ->
      with :ok <- assert_lease_and_version(attempt, now),
           analysis when not is_nil(analysis) <- lock_analysis(attempt.intake_case.id, attempt.version) do
        analysis
        |> IntakeAnalysis.changeset(%{input_snapshot: input_snapshot, work_run_id: attempt.work_run.id})
        |> Repo.update!()

        :ok
      else
        nil -> {:error, :analysis_context_not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> transaction_result()
  end

  defp call_model(snapshot_path, prompt, issue, analysis, delivery, deadline_ms, opts) do
    capture_key = {:intake_analysis_capture, make_ref()}
    Process.put(capture_key, %{text: "", usage: nil})

    try do
      on_message = fn message ->
        capture = Process.get(capture_key, %{text: "", usage: nil})
        delta = message_delta(message)
        usage = usage_from_message(message) || capture.usage

        Process.put(capture_key, %{
          text: capture.text <> delta,
          usage: usage
        })
      end

      heartbeat_fun = fn -> heartbeat_delivery(delivery) end
      model_options = [deadline_ms: deadline_ms, on_message: on_message, heartbeat_fun: heartbeat_fun]

      response =
        case Keyword.get(opts, :model_fun) do
          fun when is_function(fun, 4) ->
            fun.(snapshot_path, prompt, issue, model_options)

          _default ->
            Codex.run_analysis(snapshot_path, prompt, issue,
              analysis_policy: %{model: analysis.model, effort: analysis.effort},
              deadline_ms: deadline_ms,
              heartbeat_fun: heartbeat_fun,
              on_message: on_message
            )
        end

      captured = Process.get(capture_key, %{text: "", usage: nil})
      normalize_model_response(response, captured)
    rescue
      _exception -> {:error, :analysis_backend_failed}
    catch
      :exit, _reason -> {:error, :analysis_backend_failed}
    after
      Process.delete(capture_key)
    end
  end

  defp heartbeat_delivery(%IntegrationDelivery{id: id, lease_token: token}) when is_binary(token) do
    case SymphonyElixir.Intake.Outbox.heartbeat(id, token) do
      {:ok, _delivery} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp heartbeat_delivery(_delivery), do: {:error, :stale_lease}

  defp normalize_model_response({:ok, response}, captured) when is_map(response), do: {:ok, response, captured}
  defp normalize_model_response({:error, reason}, _captured), do: {:error, {:analysis_backend_failed, reason}}
  defp normalize_model_response(_response, _captured), do: {:error, :analysis_backend_failed}

  defp model_output(response, captured) do
    case response_value(response, :result) do
      raw when is_binary(raw) -> {:ok, raw}
      _other when is_binary(captured.text) and captured.text != "" -> {:ok, captured.text}
      _other -> {:error, :invalid_analysis_response}
    end
  end

  defp model_usage(response, captured) do
    usage = response_value(response, :usage) || get_in(response, [:metadata, :usage]) || captured.usage

    if is_map(usage) do
      usage
      |> Enum.filter(fn {key, value} -> usage_key?(key) and is_integer(value) and value >= 0 end)
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
    else
      %{}
    end
  end

  defp response_value(response, key) when is_map(response), do: Map.get(response, key) || Map.get(response, to_string(key))
  defp response_value(_response, _key), do: nil

  defp usage_key?(key), do: to_string(key) in ~w(input_tokens cached_input_tokens output_tokens total_tokens)

  defp message_delta(%{payload: payload}) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["codex/event/agent_message_delta", "codex/event/agent_message_content_delta", "item/agentMessage/delta"] do
      first_binary(payload, [
        ["params", "delta"],
        ["params", "textDelta"],
        ["params", "text"],
        ["params", "msg", "delta"],
        ["params", "msg", "textDelta"],
        ["params", "msg", "text"]
      ])
    else
      ""
    end
  end

  defp message_delta(_message), do: ""

  defp first_binary(map, paths) do
    Enum.find_value(paths, "", fn path ->
      case get_nested(map, path) do
        value when is_binary(value) -> value
        _other -> nil
      end
    end)
  end

  defp get_nested(value, []), do: value
  defp get_nested(map, [key | rest]) when is_map(map), do: get_nested(Map.get(map, key), rest)
  defp get_nested(_value, _path), do: nil

  defp usage_from_message(%{usage: usage}) when is_map(usage), do: usage
  defp usage_from_message(%{payload: %{"params" => %{"usage" => usage}}}) when is_map(usage), do: usage
  defp usage_from_message(_message), do: nil

  defp finish_attempt(delivery, attempt, {:ok, outcome}, opts) do
    case persist_success(delivery, attempt, outcome, opts) do
      :ok ->
        {:ok, %{provider_id: "analysis:#{attempt.intake_case.id}:v#{attempt.version}"}}

      {:error, reason} when reason in [:stale_lease, :stale_analysis_version] ->
        mark_stale_work_run(attempt, reason, opts)

      {:error, reason} ->
        {:retry, error_code(reason), nil}
    end
  end

  defp finish_attempt(delivery, attempt, {:error, reason}, opts) do
    code = error_code(reason)
    technical? = technical_failure?(reason)

    case persist_failure(delivery, attempt, code, opts) do
      :ok ->
        if technical? and delivery.attempts < @max_model_starts,
          do: {:retry, code, nil},
          else: {:error, code}

      {:error, reason} when reason in [:stale_lease, :stale_analysis_version] ->
        mark_stale_work_run(attempt, reason, opts)

      {:error, _persist_reason} ->
        {:retry, "analysis_result_persist_failed", nil}
    end
  end

  defp finish_attempt(_delivery, attempt, _other, opts) do
    finish_attempt(%IntegrationDelivery{attempts: @max_model_starts}, attempt, {:error, :analysis_failed}, opts)
  end

  defp persist_success(delivery, attempt, outcome, opts) do
    now = current_time(opts)
    case_status = if outcome.result["needs_input"], do: "needs_input", else: "ready"
    analysis_status = if outcome.result["needs_input"], do: "needs_input", else: "succeeded"

    Repo.transaction(fn ->
      with :ok <- assert_lease_and_version(attempt, now),
           analysis when not is_nil(analysis) <- lock_analysis(attempt.intake_case.id, attempt.version),
           intake_case when not is_nil(intake_case) <- lock_case(attempt.intake_case.id),
           work_run when not is_nil(work_run) <- Repo.get(WorkRun, attempt.work_run.id) do
        analysis
        |> IntakeAnalysis.changeset(%{
          status: analysis_status,
          input_snapshot: outcome.input_snapshot,
          result: outcome.result,
          model: outcome.model,
          effort: outcome.effort,
          token_usage: outcome.token_usage,
          completed_at: now,
          error_code: nil
        })
        |> Repo.update!()

        intake_case
        |> IntakeCase.changeset(%{analysis_status: case_status, lock_version: intake_case.lock_version + 1})
        |> Repo.update!()

        update_work_run!(work_run, "succeeded", outcome.token_usage, nil)
        enqueue_comment!(delivery, intake_case, attempt.version, now)

        record_event!(
          intake_case,
          "analysis_completed",
          %{
            version: attempt.version,
            work_run_id: work_run.id,
            status: analysis_status
          },
          now
        )

        :ok
      else
        nil -> {:error, :analysis_context_not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> transaction_result()
  end

  defp persist_failure(delivery, attempt, code, opts) do
    now = current_time(opts)

    Repo.transaction(fn ->
      with :ok <- assert_lease_and_version(attempt, now),
           analysis when not is_nil(analysis) <- lock_analysis(attempt.intake_case.id, attempt.version),
           intake_case when not is_nil(intake_case) <- lock_case(attempt.intake_case.id),
           work_run when not is_nil(work_run) <- Repo.get(WorkRun, attempt.work_run.id) do
        analysis
        |> IntakeAnalysis.changeset(%{status: "failed", completed_at: now, error_code: code})
        |> Repo.update!()

        intake_case
        |> IntakeCase.changeset(%{analysis_status: "failed", lock_version: intake_case.lock_version + 1})
        |> Repo.update!()

        update_work_run!(work_run, "failed", nil, code)

        record_event!(
          intake_case,
          "analysis_failed",
          %{
            version: attempt.version,
            work_run_id: work_run.id,
            error_code: code,
            attempts: delivery.attempts
          },
          now
        )

        :ok
      else
        nil -> {:error, :analysis_context_not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> transaction_result()
  end

  defp enqueue_comment!(delivery, intake_case, version, now) do
    dedupe_key = "case:#{intake_case.id}:jira-comment:#{version}"

    unless Repo.exists?(from(comment in IntegrationDelivery, where: comment.dedupe_key == ^dedupe_key)) do
      %IntegrationDelivery{}
      |> IntegrationDelivery.changeset(%{
        case_id: intake_case.id,
        connection_id: intake_case.jira_connection_id,
        operation: "jira_comment",
        dedupe_key: dedupe_key,
        payload: %{
          "version" => version,
          "case_ref" => "jira_#{intake_case.id}",
          "jira_key" => intake_case.jira_key,
          "analysis_delivery_id" => delivery.id
        },
        status: "pending",
        attempts: 0,
        next_attempt_at: now,
        lock_version: 1
      })
      |> Repo.insert!()

      record_event!(intake_case, "delivery_queued", %{operation: "jira_comment", version: version}, now)
    end
  end

  defp update_work_run!(work_run, status, usage, error_code) do
    payload =
      work_run.payload
      |> Map.put("token_usage", usage || %{})
      |> maybe_put_error(error_code)

    work_run
    |> WorkRun.changeset(%{status: status, payload: payload})
    |> Repo.update!()
  end

  defp maybe_put_error(payload, nil), do: Map.delete(payload, "error_code")
  defp maybe_put_error(payload, error_code), do: Map.put(payload, "error_code", error_code)

  defp assert_lease_and_version(attempt, now) do
    with {:ok, _delivery} <- leased_delivery(attempt.delivery, now),
         %IntakeCase{analysis_version: version} when version == attempt.version <- lock_case(attempt.intake_case.id) do
      :ok
    else
      nil -> {:error, :stale_analysis_version}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :stale_analysis_version}
    end
  end

  defp leased_delivery(%IntegrationDelivery{id: id, lease_token: token}, now) when is_binary(token) do
    case Repo.one(
           from(delivery in IntegrationDelivery,
             where:
               delivery.id == ^id and delivery.operation == "analysis" and
                 delivery.status == "running" and delivery.lease_token == ^token and
                 delivery.lease_until > ^now,
             lock: "FOR UPDATE"
           )
         ) do
      %IntegrationDelivery{} = delivery -> {:ok, delivery}
      nil -> {:error, :stale_lease}
    end
  end

  defp leased_delivery(_delivery, _now), do: {:error, :stale_lease}

  defp lock_case(case_id) do
    Repo.one(from(intake_case in IntakeCase, where: intake_case.id == ^case_id, lock: "FOR UPDATE"))
  end

  defp lock_analysis(case_id, version) do
    Repo.one(
      from(analysis in IntakeAnalysis,
        where: analysis.case_id == ^case_id and analysis.version == ^version,
        lock: "FOR UPDATE"
      )
    )
  end

  defp record_event!(intake_case, type, payload, now) do
    %IntakeEvent{}
    |> IntakeEvent.changeset(%{
      case_id: intake_case.id,
      rule_id: intake_case.rule_id,
      type: type,
      payload: stringify_keys(payload),
      actor: "system",
      occurred_at: now
    })
    |> Repo.insert!()
  end

  defp mark_stale_work_run(attempt, reason, opts) do
    now = current_time(opts)

    Repo.update_all(
      from(analysis in IntakeAnalysis,
        where:
          analysis.case_id == ^attempt.intake_case.id and analysis.version == ^attempt.version and
            analysis.work_run_id == ^attempt.work_run.id and analysis.status == "running"
      ),
      set: [status: "failed", completed_at: now, error_code: error_code(reason), updated_at: now]
    )

    case Repo.get(WorkRun, attempt.work_run.id) do
      %WorkRun{status: "running"} = work_run ->
        update_work_run!(work_run, "failed", nil, error_code(reason))
        {:error, error_code(reason)}

      _other ->
        {:error, error_code(reason)}
    end
  rescue
    _exception -> {:error, error_code(reason)}
  end

  defp cleanup_snapshot(workspace_root, case_id, version, opts) do
    result =
      case Keyword.get(opts, :cleanup_fun) do
        fun when is_function(fun, 3) -> fun.(workspace_root, case_id, version)
        _default -> AnalysisContext.cleanup(workspace_root, case_id, version)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_cleanup_result}
    end
  rescue
    _exception -> {:error, :snapshot_cleanup_exception}
  catch
    _kind, _reason -> {:error, :snapshot_cleanup_exception}
  end

  defp workspace_root(opts) do
    case Keyword.get(opts, :workspace_root) do
      root when is_binary(root) -> root
      _missing -> Config.settings!().workspace.root
    end
  end

  defp timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _missing -> Config.analysis_settings().timeout_ms
    end
  end

  defp remaining_ms(deadline_ms, opts), do: deadline_ms - monotonic_time(opts)

  defp monotonic_time(opts) do
    case Keyword.get(opts, :monotonic_time_fun) do
      fun when is_function(fun, 0) -> fun.()
      _default -> System.monotonic_time(:millisecond)
    end
  end

  defp current_time(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> now
      _missing -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp payload_version(payload) when is_map(payload), do: integer_value(Map.get(payload, "version") || Map.get(payload, :version))
  defp payload_version(_payload), do: nil

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp error_code(:analysis_timeout), do: "analysis_timeout"
  defp error_code({:analysis_backend_failed, _reason}), do: "analysis_backend_failed"
  defp error_code(:analysis_backend_failed), do: "analysis_backend_failed"
  defp error_code(:analysis_context_failed), do: "analysis_context_failed"
  defp error_code(:analysis_failed), do: "analysis_failed"
  defp error_code(:analysis_result_persist_failed), do: "analysis_result_persist_failed"
  defp error_code(:analysis_attempt_limit_reached), do: "analysis_attempt_limit_reached"
  defp error_code(:invalid_analysis_response), do: "invalid_analysis_response"
  defp error_code(:invalid_json), do: "invalid_json"
  defp error_code(:result_too_large), do: "result_too_large"
  defp error_code(:invalid_source), do: "invalid_source"
  defp error_code(:html_result), do: "html_result"
  defp error_code({:unsafe_archive, _reason}), do: "unsafe_repository_snapshot"
  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "analysis_failed"

  defp technical_failure?(:analysis_timeout), do: true
  defp technical_failure?(:analysis_backend_failed), do: true
  defp technical_failure?({:analysis_backend_failed, _reason}), do: true
  defp technical_failure?(:analysis_context_failed), do: true
  defp technical_failure?(_reason), do: false

  defp transaction_result({:ok, {:ok, value}}), do: {:ok, value}
  defp transaction_result({:ok, :ok}), do: :ok
  defp transaction_result({:ok, {:error, reason}}), do: {:error, reason}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
