defmodule SymphonyElixir.Notifications.Smsapi do
  @moduledoc """
  SMSAPI transport for intake alerts, without an SDK.

  Each call makes at most one POST form request to the fixed
  `https://api.smsapi.pl/sms.do` endpoint with a Bearer token header and the
  delivery UUID as `idx` with `check_idx=1`. Req retries and redirects are off.
  The token and the recipient number never appear in the URL, logs or crash
  reports: the request runs in an isolated process whose failures are caught.

  Results follow the `SymphonyElixir.Intake.Dispatcher` adapter contract.
  HTTP 200 is not success by itself: the body and the recipient status are
  validated. Error 53 (duplicate `idx`) means SMSAPI already accepted this
  delivery, so it completes without a new message. Any outcome that cannot
  prove the SMS was not accepted (timeouts, 5xx, crashes, unexpected bodies)
  is `unknown` and is never resent automatically.
  """

  alias SymphonyElixir.Notifications.Templates
  alias SymphonyElixir.Storage.IntegrationConnection

  @endpoint "https://api.smsapi.pl/sms.do"
  @default_timeout_ms 30_000
  @e164_pattern ~r/\A\+[1-9]\d{6,14}\z/
  @phone_separators ~r/[\s().-]/u
  @accepted_statuses ~w(QUEUE ACCEPTED PENDING SENT DELIVERED)
  @rejected_statuses ~w(UNDELIVERED EXPIRED REJECTED FAILED NOT_FOUND STOP)
  @duplicate_idx 53
  @refused_before_send [:econnrefused, :nxdomain, :ehostunreach, :enetunreach]

  @type sms :: %{delivery_id: String.t(), recipient: String.t(), message: String.t()}
  @type delivery_result ::
          {:ok, %{provider_id: String.t() | nil}}
          | {:retry, String.t(), String.t() | nil}
          | {:error, String.t()}
          | {:unknown, String.t()}

  @spec deliver_sms(sms(), IntegrationConnection.t(), keyword()) :: delivery_result()
  def deliver_sms(%{delivery_id: delivery_id, recipient: recipient, message: message}, %IntegrationConnection{} = connection, opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    with :ok <- validate_idx(delivery_id),
         {:ok, e164} <- normalize_phone(recipient),
         :ok <- validate_message(message),
         {:ok, token, sender} <- credentials(connection) do
      request = [
        method: :post,
        url: @endpoint,
        headers: [{"authorization", "Bearer " <> token}],
        form: [
          to: String.trim_leading(e164, "+"),
          from: sender,
          message: message,
          format: "json",
          encoding: "utf-8",
          idx: delivery_id,
          check_idx: "1"
        ],
        retry: false,
        redirect: false,
        receive_timeout: timeout_ms,
        connect_options: [timeout: timeout_ms]
      ]

      request_fun
      |> run_isolated(request, timeout_ms)
      |> classify()
    end
  end

  @spec normalize_phone(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_phone(phone) when is_binary(phone) do
    compact = String.replace(String.trim(phone), @phone_separators, "")

    candidate =
      case compact do
        "00" <> rest -> "+" <> rest
        other -> other
      end

    if Regex.match?(@e164_pattern, candidate), do: {:ok, candidate}, else: {:error, "sms_invalid_recipient"}
  end

  def normalize_phone(_phone), do: {:error, "sms_invalid_recipient"}

  defp validate_idx(delivery_id) do
    case Ecto.UUID.cast(delivery_id) do
      {:ok, _uuid} -> :ok
      :error -> {:error, "sms_invalid_idx"}
    end
  end

  defp validate_message(message) when is_binary(message) do
    cond do
      not String.valid?(message) or String.trim(message) == "" -> {:error, "sms_message_invalid"}
      Templates.sms_units(message) > Templates.sms_unit_limit() -> {:error, "sms_message_too_long"}
      true -> :ok
    end
  end

  defp validate_message(_message), do: {:error, "sms_message_invalid"}

  defp credentials(%IntegrationConnection{kind: "smsapi", secret: token, settings: settings}) do
    sender = normalize_sender(sender_setting(settings))

    cond do
      not is_binary(token) or String.trim(token) == "" -> {:error, "sms_credentials_missing"}
      is_nil(sender) -> {:error, "sms_invalid_settings"}
      true -> {:ok, token, sender}
    end
  end

  defp credentials(%IntegrationConnection{}), do: {:error, "sms_invalid_settings"}

  defp normalize_sender(sender) when is_binary(sender) do
    trimmed = String.trim(sender)

    if trimmed == "" or not String.valid?(trimmed) or Regex.match?(~r/[\x00-\x1F\x7F]/, trimmed), do: nil, else: trimmed
  end

  defp normalize_sender(_sender), do: nil

  # Runs the request in a monitored process so a hung socket is cut at the
  # timeout and a crash is caught without a crash report, because the request
  # arguments carry the token and the recipient number.
  defp run_isolated(request_fun, request, timeout_ms) do
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:done, request_fun.(request)}
          catch
            _kind, _reason -> :crashed
          end

        send(caller, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :crashed
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^ref, result} -> result
        after
          0 -> :timeout
        end
    end
  end

  defp classify(:timeout), do: {:unknown, "sms_timeout"}
  defp classify(:crashed), do: {:unknown, "sms_outcome_unknown"}

  defp classify({:done, {:ok, %{status: status} = response}}) when is_integer(status),
    do: classify_response(status, response)

  defp classify({:done, {:error, %{reason: reason}}}), do: transport_error(reason)
  defp classify({:done, {:error, reason}}), do: transport_error(reason)
  defp classify({:done, _unexpected}), do: {:unknown, "sms_outcome_unknown"}

  defp classify_response(status, response) do
    case decode_body(Map.get(response, :body)) do
      %{"error" => code} -> provider_error(error_code(code))
      body -> classify_status(status, body, response)
    end
  end

  defp classify_status(200, body, _response), do: accepted(body)
  defp classify_status(status, _body, _response) when status in [401, 403], do: {:error, "sms_auth_failed"}
  defp classify_status(429, _body, response), do: {:retry, "sms_rate_limited", retry_after(response)}
  defp classify_status(status, _body, _response) when status in 400..499, do: {:error, "sms_rejected"}
  defp classify_status(_status, _body, _response), do: {:unknown, "sms_outcome_unknown"}

  defp accepted(%{"list" => [%{"id" => id, "status" => status}]} = body)
       when is_binary(id) and id != "" and is_binary(status) do
    cond do
      Map.get(body, "count", 1) != 1 -> {:unknown, "sms_outcome_unknown"}
      status in @accepted_statuses -> {:ok, %{provider_id: id}}
      status in @rejected_statuses -> {:error, "sms_rejected"}
      true -> {:unknown, "sms_outcome_unknown"}
    end
  end

  defp accepted(_body), do: {:unknown, "sms_outcome_unknown"}

  # SMSAPI error codes: https://www.smsapi.pl/docs/ ("Kody błędów").
  defp provider_error(@duplicate_idx), do: {:ok, %{provider_id: nil}}
  defp provider_error(code) when code in [101, 102, 105], do: {:error, "sms_auth_failed"}
  defp provider_error(103), do: {:error, "sms_insufficient_points"}
  defp provider_error(code) when code in [13, 33, 57, 59, 112], do: {:error, "sms_invalid_recipient"}
  defp provider_error(14), do: {:error, "sms_invalid_sender"}
  defp provider_error(code) when code in [11, 12], do: {:error, "sms_message_rejected"}
  defp provider_error(code) when code in [52, 200, 202, 203], do: {:retry, "sms_provider_busy", nil}
  defp provider_error(code) when code in [8, 201, 999], do: {:unknown, "sms_provider_internal_error"}
  defp provider_error(nil), do: {:unknown, "sms_outcome_unknown"}
  defp provider_error(_code), do: {:error, "sms_provider_error"}

  defp error_code(code) when is_integer(code), do: code

  defp error_code(code) when is_binary(code) do
    case Integer.parse(String.trim(code)) do
      {value, ""} -> value
      _invalid -> nil
    end
  end

  defp error_code(_code), do: nil

  defp transport_error(reason) when reason in @refused_before_send, do: {:retry, "sms_unavailable", nil}
  defp transport_error(:timeout), do: {:unknown, "sms_timeout"}
  defp transport_error(_reason), do: {:unknown, "sms_outcome_unknown"}

  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _invalid -> nil
    end
  end

  defp decode_body(_body), do: nil

  defp retry_after(response) do
    case Map.get(response, :headers) do
      %{} = headers -> headers |> Map.get("retry-after") |> first_value()
      headers when is_list(headers) -> headers |> List.keyfind("retry-after", 0) |> header_tuple_value()
      _missing -> nil
    end
  end

  defp header_tuple_value({_name, value}), do: first_value(value)
  defp header_tuple_value(nil), do: nil

  defp first_value([value | _rest]) when is_binary(value), do: value
  defp first_value(value) when is_binary(value), do: value
  defp first_value(_value), do: nil

  defp sender_setting(%{} = settings), do: Map.get(settings, "sender", Map.get(settings, :sender))
  defp sender_setting(_settings), do: nil
end
