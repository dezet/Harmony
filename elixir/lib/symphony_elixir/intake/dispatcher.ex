defmodule SymphonyElixir.Intake.Dispatcher do
  @moduledoc """
  Claims one outbox effect, performs its adapter call after the claim transaction
  commits, then persists the result through the delivery's lease token.

  E-mail and SMS alerts are rendered per delivery from the case, its rule
  snapshot and the configured Harmony `intake.public_url`, then handed to
  `Notifications.Smtp` or `Notifications.Smsapi`. A missing public URL or
  connection is an explicit failure; no link or credential is invented.
  An SMS test-send is a case-less delivery with `payload.test_send == true`.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Intake.{AnalysisRunner, CommentPublisher, LinearBridge, Outbox}
  alias SymphonyElixir.Notifications.{Smsapi, Smtp, Templates}
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{IntakeCase, IntegrationConnection, IntegrationDelivery}

  @type adapter :: (IntegrationDelivery.t() -> term()) | module()
  @type dispatch_result ::
          :empty
          | {:ok, IntegrationDelivery.t()}
          | {:retry_wait, IntegrationDelivery.t()}
          | {:failed, IntegrationDelivery.t()}
          | {:unknown, IntegrationDelivery.t()}
          | {:error, term()}

  @spec dispatch_one(adapter(), keyword()) :: dispatch_result()
  def dispatch_one(adapter, opts) do
    case Outbox.claim(opts) do
      :empty ->
        :empty

      {:error, reason} ->
        {:error, reason}

      {:ok, %IntegrationDelivery{} = delivery} ->
        deliver(adapter, delivery, opts)
    end
  end

  @spec dispatch_one(adapter()) :: dispatch_result()
  def dispatch_one(adapter) when is_function(adapter, 1) or is_atom(adapter), do: dispatch_one(adapter, [])

  @spec dispatch_one(keyword()) :: dispatch_result()
  def dispatch_one(opts) when is_list(opts) do
    dispatch_one(fn delivery -> default_adapter(delivery, opts) end, opts)
  end

  defp deliver(adapter, delivery, opts) do
    case call_adapter(adapter, delivery) do
      {:ok, attrs} when is_map(attrs) ->
        Outbox.complete(delivery.id, delivery.lease_token, attrs, opts)

      {:retry, error_code, retry_after} ->
        persist_retry(delivery, error_code, retry_after, opts)

      {:error, error_code} ->
        with {:ok, updated} <- Outbox.fail(delivery.id, delivery.lease_token, error_code, opts) do
          {:failed, updated}
        end

      {:unknown, error_code} ->
        with {:ok, updated} <- Outbox.mark_unknown(delivery.id, delivery.lease_token, error_code, opts) do
          {:unknown, updated}
        end

      result ->
        {:error, {:invalid_adapter_result, result}}
    end
  end

  defp persist_retry(delivery, error_code, retry_after, opts) do
    with {:ok, updated} <- Outbox.retry(delivery.id, delivery.lease_token, error_code, retry_after, opts) do
      retry_result(updated)
    end
  end

  defp retry_result(%IntegrationDelivery{status: "retry_wait"} = delivery), do: {:retry_wait, delivery}
  defp retry_result(%IntegrationDelivery{} = delivery), do: {:failed, delivery}

  defp call_adapter(adapter, delivery) when is_function(adapter, 1), do: adapter.(delivery)
  defp call_adapter(adapter, delivery) when is_atom(adapter), do: adapter.perform(delivery)

  defp default_adapter(%IntegrationDelivery{operation: "linear_create"} = delivery, opts) do
    LinearBridge.perform(delivery, Keyword.get(opts, :linear_bridge_opts, []))
  end

  defp default_adapter(%IntegrationDelivery{operation: "analysis"} = delivery, opts) do
    AnalysisRunner.perform(delivery, Keyword.get(opts, :analysis_opts, []))
  end

  defp default_adapter(%IntegrationDelivery{operation: "jira_comment"} = delivery, opts) do
    CommentPublisher.perform(delivery, Keyword.get(opts, :jira_comment_opts, []))
  end

  defp default_adapter(%IntegrationDelivery{operation: "email"} = delivery, opts) do
    case email_message(delivery) do
      {:ok, email, connection} -> Smtp.deliver_email(email, connection, Keyword.get(opts, :smtp_opts, []))
      {:retry, code} -> {:retry, code, nil}
      {:error, code} -> {:error, code}
    end
  end

  defp default_adapter(%IntegrationDelivery{operation: "sms"} = delivery, opts) do
    case sms_message(delivery) do
      {:ok, message, connection} ->
        sms = %{delivery_id: delivery.id, recipient: payload_value(delivery.payload, "recipient"), message: message}
        Smsapi.deliver_sms(sms, connection, Keyword.get(opts, :sms_opts, []))

      {:retry, code} ->
        {:retry, code, nil}

      {:error, code} ->
        {:error, code}
    end
  end

  defp default_adapter(%IntegrationDelivery{} = delivery, opts) do
    case Keyword.get(opts, :io_adapter) do
      fun when is_function(fun, 1) -> fun.(delivery)
      module when is_atom(module) -> module.perform(delivery)
      _missing -> {:error, "unsupported_delivery_operation"}
    end
  end

  # Everything below runs before any message is handed to a transport, so a
  # local failure (database, configuration) is safe to retry.
  defp email_message(%IntegrationDelivery{} = delivery) do
    with {:ok, connection} <- notification_connection(delivery, "smtp"),
         {:ok, intake_case} <- notification_case(delivery),
         {:ok, harmony_url} <- case_link(intake_case),
         attrs = email_attrs(delivery, connection, intake_case, harmony_url),
         {:ok, email} <- attrs |> Templates.render_email() |> template_result() do
      {:ok, email, connection}
    end
  rescue
    _exception -> {:retry, "notification_local_state_unavailable"}
  catch
    :exit, _reason -> {:retry, "notification_local_state_unavailable"}
  end

  defp sms_message(%IntegrationDelivery{case_id: nil} = delivery) do
    if payload_value(delivery.payload, "test_send") == true do
      with {:ok, connection} <- notification_connection(delivery, "smsapi") do
        {:ok, Templates.render_test_sms(), connection}
      end
    else
      {:error, "notification_case_required"}
    end
  rescue
    _exception -> {:retry, "notification_local_state_unavailable"}
  catch
    :exit, _reason -> {:retry, "notification_local_state_unavailable"}
  end

  defp sms_message(%IntegrationDelivery{} = delivery) do
    with {:ok, connection} <- notification_connection(delivery, "smsapi"),
         {:ok, intake_case} <- notification_case(delivery),
         {:ok, case_url} <- case_link(intake_case),
         {:ok, message} <-
           %{jira_key: intake_case.jira_key, priority_name: intake_case.priority_name, case_url: case_url}
           |> Templates.render_sms()
           |> template_result() do
      {:ok, message, connection}
    end
  rescue
    _exception -> {:retry, "notification_local_state_unavailable"}
  catch
    :exit, _reason -> {:retry, "notification_local_state_unavailable"}
  end

  defp notification_connection(%IntegrationDelivery{connection_id: nil}, _kind), do: {:error, "connection_required"}

  defp notification_connection(%IntegrationDelivery{connection_id: connection_id}, kind) do
    case Repo.get(IntegrationConnection, connection_id) do
      %IntegrationConnection{kind: ^kind, enabled: true} = connection -> {:ok, connection}
      %IntegrationConnection{kind: ^kind} -> {:retry, "connection_disabled"}
      _other -> {:error, "notification_connection_unavailable"}
    end
  end

  defp notification_case(%IntegrationDelivery{case_id: nil}), do: {:error, "notification_case_required"}

  defp notification_case(%IntegrationDelivery{case_id: case_id}) do
    case Repo.get(IntakeCase, case_id) do
      %IntakeCase{} = intake_case -> {:ok, intake_case}
      nil -> {:error, "notification_case_not_found"}
    end
  end

  defp case_link(%IntakeCase{id: case_id}) do
    case Config.intake_settings().public_url do
      url when is_binary(url) and url != "" ->
        case Templates.case_url(url, case_id) do
          {:ok, case_url} -> {:ok, case_url}
          {:error, :invalid_link} -> {:error, "invalid_intake_public_url"}
        end

      _missing ->
        {:error, "missing_intake_public_url"}
    end
  end

  defp email_attrs(delivery, connection, intake_case, harmony_url) do
    settings = connection.settings || %{}

    %{
      delivery_id: delivery.id,
      recipient: payload_value(delivery.payload, "recipient"),
      from_email: payload_value(settings, "from_email"),
      from_name: payload_value(settings, "from_name"),
      message_id_domain: payload_value(settings, "message_id_domain"),
      priority_name: intake_case.priority_name,
      jira_key: intake_case.jira_key,
      project_name: payload_value(intake_case.rule_snapshot || %{}, "project_name"),
      title: intake_case.title,
      jira_url: intake_case.jira_url,
      harmony_url: harmony_url,
      detected_at: intake_case.detected_at
    }
  end

  defp template_result({:ok, rendered}), do: {:ok, rendered}
  defp template_result({:error, :message_too_long}), do: {:error, "sms_message_too_long"}
  defp template_result({:error, {:missing_field, field}}), do: {:error, "notification_missing_#{field}"}
  defp template_result({:error, reason}), do: {:error, "notification_#{reason}"}

  # Payloads, settings and snapshots are reloaded from jsonb, so keys are strings.
  defp payload_value(map, key) when is_map(map), do: Map.get(map, key)
  defp payload_value(_map, _key), do: nil
end
