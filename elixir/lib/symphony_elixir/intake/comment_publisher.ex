defmodule SymphonyElixir.Intake.CommentPublisher do
  @moduledoc "Publishes validated intake analyses to Jira with marker-based reconciliation."

  import Ecto.Query

  alias SymphonyElixir.Intake.CommentRenderer
  alias SymphonyElixir.Jira.{Adf, CloudClient}
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{IntakeAnalysis, IntakeCase, IntakeEvent, IntegrationConnection, IntegrationDelivery}

  @property_key "harmony.analysis"

  @type publish_result ::
          {:ok, %{provider_id: String.t()}}
          | {:retry, String.t(), String.t() | nil}
          | {:error, String.t()}
          | {:unknown, String.t()}

  @spec perform(IntegrationDelivery.t()) :: publish_result()
  def perform(delivery), do: perform(delivery, [])

  @spec perform(IntegrationDelivery.t(), keyword()) :: publish_result()
  def perform(%IntegrationDelivery{operation: "jira_comment", case_id: case_id} = delivery, opts)
      when is_binary(case_id) and is_list(opts) do
    with {:ok, intake_case, analysis, version} <- load_result(delivery),
         :ok <- current_version(intake_case, version),
         {:ok, connection} <- load_connection(intake_case),
         {:ok, client_opts} <- client_opts(connection, opts),
         rendered = CommentRenderer.render(intake_case, version, analysis.result, analysis.input_snapshot),
         {:ok, comments} <- CloudClient.list_comments(intake_case.jira_issue_id, client_opts) do
      case Enum.find(comments, &marker_match?(&1, rendered.marker)) do
        %{"id" => id} when is_binary(id) -> {:ok, %{provider_id: id}}
        nil -> post_once(delivery, intake_case, version, rendered, client_opts, opts)
        _comment -> {:unknown, "jira_comment_marker_found_without_id"}
      end
    else
      {:error, :stale_analysis_version} -> {:error, "stale_analysis_version"}
      {:error, :analysis_result_not_ready} -> {:error, "analysis_result_not_ready"}
      {:error, :jira_connection_unavailable} -> {:error, "jira_connection_unavailable"}
      {:error, %{kind: :http_status, status: status} = error} -> read_error(status, error)
      {:error, _reason} -> {:retry, "jira_comment_read_failed", nil}
    end
  rescue
    _exception -> {:retry, "jira_comment_local_state_unavailable", nil}
  catch
    :exit, _reason -> {:retry, "jira_comment_local_state_unavailable", nil}
  end

  def perform(%IntegrationDelivery{}, _opts), do: {:error, "invalid_jira_comment_delivery"}

  @spec reconcile(IntegrationDelivery.t()) :: :safe_to_retry | :already_applied | :unknown
  def reconcile(delivery), do: reconcile(delivery, [])

  @spec reconcile(IntegrationDelivery.t(), keyword()) :: :safe_to_retry | :already_applied | :unknown
  def reconcile(%IntegrationDelivery{operation: "jira_comment"} = delivery, opts) do
    with {:ok, intake_case, _analysis, _version} <- load_result(delivery),
         {:ok, connection} <- load_connection(intake_case),
         {:ok, client_opts} <- client_opts(connection, opts),
         marker <- marker(intake_case.id, payload_version(delivery.payload)),
         {:ok, comments} <- CloudClient.list_comments(intake_case.jira_issue_id, client_opts) do
      if Enum.any?(comments, &marker_match?(&1, marker)), do: :already_applied, else: :safe_to_retry
    else
      _other -> :unknown
    end
  rescue
    _exception -> :unknown
  catch
    :exit, _reason -> :unknown
  end

  def reconcile(%IntegrationDelivery{}, _opts), do: :unknown

  defp load_result(%IntegrationDelivery{case_id: case_id, payload: payload}) do
    version = payload_version(payload)

    with true <- is_integer(version) and version > 0,
         %IntakeCase{} = intake_case <- Repo.get(IntakeCase, case_id),
         %IntakeAnalysis{status: status, result: result} = analysis
         when status in ["succeeded", "needs_input"] and is_map(result) <-
           Repo.get_by(IntakeAnalysis, case_id: case_id, version: version) do
      {:ok, intake_case, analysis, version}
    else
      false -> {:error, :analysis_result_not_ready}
      nil -> {:error, :analysis_result_not_ready}
      _other -> {:error, :analysis_result_not_ready}
    end
  end

  defp current_version(%IntakeCase{analysis_version: version}, version), do: :ok
  defp current_version(_intake_case, _version), do: {:error, :stale_analysis_version}

  defp load_connection(%IntakeCase{jira_connection_id: connection_id}) do
    case Repo.get(IntegrationConnection, connection_id) do
      %IntegrationConnection{kind: "jira_cloud", enabled: true, secret: secret} = connection
      when is_binary(secret) and secret != "" ->
        {:ok, connection}

      _other ->
        {:error, :jira_connection_unavailable}
    end
  end

  defp client_opts(%IntegrationConnection{} = connection, opts) do
    settings = connection.settings || %{}

    credentials = [
      token: connection.secret,
      auth_mode: setting(settings, "auth_mode"),
      site_url: setting(settings, "site_url"),
      account_email: setting(settings, "account_email"),
      cloud_id: setting(settings, "cloud_id")
    ]

    {:ok, Keyword.merge(credentials, Keyword.take(opts, [:request_fun, :timeout_ms]))}
  end

  defp post_once(delivery, intake_case, version, rendered, client_opts, opts) do
    manual_retry = payload_integer(delivery.payload, "manual_retries", 0)

    cond do
      ambiguous_post_exists?(delivery.id) and manual_retry == 0 ->
        {:unknown, "jira_comment_outcome_unknown"}

      true ->
        post_key = "lease-#{delivery.attempts}-manual-#{manual_retry}"

        with :ok <- record_post_started(delivery, intake_case, version, post_key, rendered.marker, opts) do
          case CloudClient.create_comment(
                 intake_case.jira_issue_id,
                 rendered.body,
                 [rendered.property],
                 client_opts
               ) do
            {:ok, %{"id" => id}} when is_binary(id) and id != "" ->
              {:ok, %{provider_id: id}}

            {:ok, _response} ->
              reconcile_ambiguous_post(intake_case, rendered.marker, client_opts)

            {:error, %{kind: :http_status, status: status} = error} ->
              handle_post_http_error(
                delivery,
                intake_case,
                post_key,
                status,
                error,
                rendered.marker,
                client_opts,
                opts
              )

            {:error, _reason} ->
              reconcile_ambiguous_post(intake_case, rendered.marker, client_opts)
          end
        else
          {:error, :post_already_attempted} -> {:unknown, "jira_comment_outcome_unknown"}
          {:error, :stale_lease} -> {:error, "stale_lease"}
          {:error, _reason} -> {:retry, "jira_comment_local_state_unavailable", nil}
        end
    end
  end

  defp handle_post_http_error(delivery, intake_case, post_key, status, error, marker, client_opts, opts) do
    cond do
      status == 429 ->
        record_post_rejected(delivery, intake_case, post_key, opts)
        {:retry, "jira_rate_limited", Map.get(error, :retry_after)}

      status in [401, 403] ->
        {:error, "jira_comment_permission_denied"}

      status in 400..499 ->
        {:error, "jira_comment_rejected"}

      true ->
        reconcile_ambiguous_post(intake_case, marker, client_opts)
    end
  end

  defp reconcile_ambiguous_post(intake_case, marker, client_opts) do
    with {:ok, comments} <- CloudClient.list_comments(intake_case.jira_issue_id, client_opts) do
      case Enum.find(comments, &marker_match?(&1, marker)) do
        %{"id" => id} when is_binary(id) and id != "" -> {:ok, %{provider_id: id}}
        nil -> {:unknown, "jira_comment_outcome_unknown"}
        _comment -> {:unknown, "jira_comment_marker_found_without_id"}
      end
    else
      _error -> {:unknown, "jira_comment_outcome_unknown"}
    end
  end

  defp record_post_started(delivery, intake_case, version, post_key, marker, opts) do
    now = current_time(opts)

    Repo.transaction(fn ->
      with :ok <- owns_lease(delivery, now),
           :ok <- case_version_is_current(intake_case.id, version),
           false <- post_event_exists?(delivery.id, post_key) do
        %IntakeEvent{}
        |> IntakeEvent.changeset(%{
          case_id: intake_case.id,
          rule_id: intake_case.rule_id,
          type: "jira_comment_post_started",
          payload: %{
            "delivery_id" => delivery.id,
            "version" => version,
            "post_key" => post_key,
            "marker" => marker
          },
          actor: "system",
          occurred_at: now
        })
        |> Repo.insert!()

        :ok
      else
        true -> {:error, :post_already_attempted}
        {:error, _reason} = error -> error
      end
    end)
    |> transaction_result()
  end

  defp record_post_rejected(delivery, intake_case, post_key, opts) do
    %IntakeEvent{}
    |> IntakeEvent.changeset(%{
      case_id: intake_case.id,
      rule_id: intake_case.rule_id,
      type: "jira_comment_post_rejected",
      payload: %{"delivery_id" => delivery.id, "post_key" => post_key},
      actor: "system",
      occurred_at: current_time(opts)
    })
    |> Repo.insert!()
  end

  defp owns_lease(%IntegrationDelivery{id: id, lease_token: token}, now) when is_binary(token) do
    case Repo.one(
           from(delivery in IntegrationDelivery,
             where:
               delivery.id == ^id and delivery.operation == "jira_comment" and
                 delivery.status == "running" and delivery.lease_token == ^token and
                 delivery.lease_until > ^now,
             lock: "FOR UPDATE"
           )
         ) do
      %IntegrationDelivery{} -> :ok
      nil -> {:error, :stale_lease}
    end
  end

  defp owns_lease(_delivery, _now), do: {:error, :stale_lease}

  defp case_version_is_current(case_id, version) do
    case Repo.one(from(intake_case in IntakeCase, where: intake_case.id == ^case_id, select: intake_case.analysis_version)) do
      ^version -> :ok
      _other -> {:error, :stale_analysis_version}
    end
  end

  defp ambiguous_post_exists?(delivery_id) do
    started =
      from(event in IntakeEvent,
        where: event.type == "jira_comment_post_started" and event.payload["delivery_id"] == ^delivery_id,
        select: event.payload["post_key"]
      )
      |> Repo.all()

    rejected =
      from(event in IntakeEvent,
        where: event.type == "jira_comment_post_rejected" and event.payload["delivery_id"] == ^delivery_id,
        select: event.payload["post_key"]
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.any?(started, &(is_binary(&1) and not MapSet.member?(rejected, &1)))
  end

  defp post_event_exists?(delivery_id, post_key) do
    Repo.exists?(
      from(event in IntakeEvent,
        where:
          event.type == "jira_comment_post_started" and event.payload["delivery_id"] == ^delivery_id and
            event.payload["post_key"] == ^post_key
      )
    )
  end

  defp marker_match?(comment, expected_marker) when is_map(comment) do
    body_match? =
      case Map.get(comment, "body") do
        body when is_map(body) -> String.contains?(Adf.to_text(body), expected_marker)
        body when is_binary(body) -> String.contains?(body, expected_marker)
        _other -> false
      end

    body_match? or property_match?(Map.get(comment, "properties"), expected_marker)
  end

  defp marker_match?(_comment, _expected_marker), do: false

  defp property_match?(properties, expected_marker) when is_list(properties) do
    Enum.any?(properties, fn
      %{"key" => @property_key, "value" => ^expected_marker} -> true
      _property -> false
    end)
  end

  defp property_match?(%{@property_key => %{"value" => value}}, expected_marker), do: value == expected_marker
  defp property_match?(_properties, _expected_marker), do: false

  defp read_error(status, _error) when status in [401, 403], do: {:error, "jira_read_permission_denied"}
  defp read_error(429, error), do: {:retry, "jira_rate_limited", Map.get(error, :retry_after)}
  defp read_error(status, _error) when status in 400..499, do: {:error, "jira_comment_read_rejected"}
  defp read_error(_status, _error), do: {:retry, "jira_comment_read_failed", nil}

  defp marker(case_id, version), do: "Harmony analysis #{case_id}/v#{version}"

  defp payload_version(payload) when is_map(payload), do: payload_integer(payload, "version", 0)
  defp payload_version(_payload), do: 0

  defp payload_integer(payload, key, default) do
    case Map.get(payload, key) || Map.get(payload, String.to_existing_atom(key)) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {number, ""} -> number
          _other -> default
        end

      _other ->
        default
    end
  rescue
    ArgumentError -> default
  end

  defp setting(settings, key), do: Map.get(settings, key) || Map.get(settings, String.to_existing_atom(key))

  defp transaction_result({:ok, :ok}), do: :ok
  defp transaction_result({:ok, {:error, reason}}), do: {:error, reason}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp current_time(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> now
      _missing -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end
end
