defmodule SymphonyElixir.Notifications.Smtp do
  @moduledoc """
  SMTP transport for intake alerts through Swoosh and gen_smtp.

  Results follow the `SymphonyElixir.Intake.Dispatcher` adapter contract.
  A definitive SMTP reply is either success, retry or failure. Anything that
  cannot prove the message was not handed over after the session opened
  (timeouts, dropped sockets, crashes) is `unknown` and is never resent here:
  gen_smtp retries are disabled and each call makes at most one attempt.

  TLS with peer and host name verification is mandatory. Plaintext is only
  accepted for an explicitly requested loopback test fixture. The relay must
  be on the runtime `intake.smtp_allowed_hosts` list and MX lookups are off,
  so no other host is contacted.
  """

  alias Swoosh.Adapters.SMTP, as: SwooshSmtp
  alias Swoosh.Email
  alias SymphonyElixir.Config
  alias SymphonyElixir.Storage.IntegrationConnection

  @default_port 587
  @default_timeout_ms 30_000
  @loopback_hosts ["127.0.0.1", "::1", "localhost"]

  @type delivery_result ::
          {:ok, %{provider_id: String.t()}}
          | {:retry, String.t(), nil}
          | {:error, String.t()}
          | {:unknown, String.t()}

  @spec deliver_email(Email.t(), IntegrationConnection.t(), keyword()) :: delivery_result()
  def deliver_email(%Email{} = email, %IntegrationConnection{} = connection, opts \\ []) do
    smtp_fun = Keyword.get(opts, :smtp_fun, &SwooshSmtp.deliver/2)

    with {:ok, message_id} <- validate_message(email),
         {:ok, smtp_options} <- smtp_options(connection, opts) do
      email
      |> run_isolated(smtp_fun, smtp_options, timeout_ms(opts))
      |> delivery_result(message_id)
    end
  end

  @spec check_connection(IntegrationConnection.t(), keyword()) :: :ok | {:error, String.t()}
  def check_connection(%IntegrationConnection{} = connection, opts \\ []) do
    open_fun = Keyword.get(opts, :open_fun, &:gen_smtp_client.open/1)
    close_fun = Keyword.get(opts, :close_fun, &:gen_smtp_client.close/1)

    with {:ok, smtp_options} <- smtp_options(connection, opts) do
      session_check = fn _unused, options -> open_and_close(open_fun, close_fun, options) end

      case run_isolated(nil, session_check, smtp_options, timeout_ms(opts)) do
        {:done, :ok} -> :ok
        {:done, {:error, code}} -> {:error, code}
        :timeout -> {:error, "smtp_timeout"}
        :crashed -> {:error, "smtp_unavailable"}
      end
    end
  end

  defp validate_message(%Email{to: [{_name, _address}], cc: [], bcc: []} = email) do
    case email.headers["Message-ID"] do
      message_id when is_binary(message_id) and message_id != "" -> {:ok, message_id}
      _missing -> {:error, "smtp_message_id_required"}
    end
  end

  defp validate_message(%Email{}), do: {:error, "smtp_single_recipient_required"}

  defp smtp_options(%IntegrationConnection{kind: "smtp"} = connection, opts) do
    settings = connection.settings || %{}
    host = settings |> setting(:host) |> normalize_host()

    with :ok <- check_allowed_host(host, opts),
         {:ok, port} <- port(setting(settings, :port)),
         {:ok, username, password} <- credentials(setting(settings, :username), connection.secret),
         {:ok, transport_options} <- transport_options(setting(settings, :tls_mode), host, opts) do
      {:ok,
       [
         relay: host,
         port: port,
         username: username,
         password: password,
         auth: :always,
         retries: 0,
         no_mx_lookups: true,
         timeout: timeout_ms(opts)
       ] ++ transport_options}
    end
  end

  defp smtp_options(%IntegrationConnection{}, _opts), do: {:error, "smtp_invalid_settings"}

  defp check_allowed_host(nil, _opts), do: {:error, "smtp_invalid_settings"}

  defp check_allowed_host(host, opts) do
    allowed =
      opts
      |> Keyword.get_lazy(:smtp_allowed_hosts, fn -> Config.intake_settings().smtp_allowed_hosts end)
      |> Enum.map(&normalize_host/1)

    if host in allowed, do: :ok, else: {:error, "smtp_host_not_allowed"}
  end

  defp port(nil), do: {:ok, @default_port}
  defp port(port) when is_integer(port) and port in 1..65_535, do: {:ok, port}

  defp port(port) when is_binary(port) do
    case Integer.parse(String.trim(port)) do
      {value, ""} -> port(value)
      _invalid -> {:error, "smtp_invalid_settings"}
    end
  end

  defp port(_port), do: {:error, "smtp_invalid_settings"}

  defp credentials(username, password) when is_binary(username) and is_binary(password) do
    if String.trim(username) == "" or password == "" do
      {:error, "smtp_credentials_missing"}
    else
      {:ok, String.trim(username), password}
    end
  end

  defp credentials(_username, _password), do: {:error, "smtp_credentials_missing"}

  defp transport_options("starttls", host, opts) do
    with {:ok, tls_options} <- verified_tls_options(host, opts) do
      {:ok, [ssl: false, tls: :always, tls_options: tls_options]}
    end
  end

  # Implicit TLS: the socket is verified at connect time, so STARTTLS is not attempted again.
  defp transport_options("tls", host, opts) do
    with {:ok, tls_options} <- verified_tls_options(host, opts) do
      {:ok, [ssl: true, tls: :never, sockopts: tls_options]}
    end
  end

  defp transport_options("none", host, opts) do
    if Keyword.get(opts, :allow_plaintext_loopback) === true and host in @loopback_hosts do
      {:ok, [ssl: false, tls: :never]}
    else
      {:error, "smtp_tls_required"}
    end
  end

  defp transport_options(_tls_mode, _host, _opts), do: {:error, "smtp_tls_required"}

  defp verified_tls_options(host, opts) do
    with {:ok, cacerts} <- cacerts(opts) do
      {:ok,
       [
         versions: [:"tlsv1.2", :"tlsv1.3"],
         verify: :verify_peer,
         cacerts: cacerts,
         depth: 10,
         server_name_indication: server_name_indication(host),
         customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
       ]}
    end
  end

  defp cacerts(opts) do
    case Keyword.get_lazy(opts, :cacerts, &system_cacerts/0) do
      [_ | _] = cacerts -> {:ok, cacerts}
      _unavailable -> {:error, "smtp_ca_store_unavailable"}
    end
  end

  defp system_cacerts do
    :public_key.cacerts_get()
  rescue
    _error -> []
  end

  defp server_name_indication(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, _address} -> :disable
      {:error, _reason} -> charlist
    end
  end

  defp open_and_close(open_fun, close_fun, smtp_options) do
    case open_fun.(smtp_options) do
      {:ok, session} ->
        close_fun.(session)
        :ok

      {:error, :bad_option, _reason} ->
        {:error, "smtp_invalid_settings"}

      {:error, type, reason} ->
        {:error, session_error_code({type, reason})}

      _unexpected ->
        {:error, "smtp_unavailable"}
    end
  end

  # Runs one transport call in a monitored process so a hung socket read is
  # cut at the request timeout. A crash is caught without a crash report, because
  # its arguments and stacktrace may carry the SMTP password.
  defp run_isolated(email, fun, smtp_options, timeout_ms) do
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:done, fun.(email, smtp_options)}
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

  defp delivery_result({:done, {:ok, _receipt}}, message_id), do: {:ok, %{provider_id: message_id}}
  defp delivery_result({:done, {:error, reason}}, _message_id), do: classify_error(reason)
  defp delivery_result({:done, _unexpected}, _message_id), do: {:unknown, "smtp_outcome_unknown"}
  defp delivery_result(:timeout, _message_id), do: {:unknown, "smtp_timeout"}
  defp delivery_result(:crashed, _message_id), do: {:unknown, "smtp_outcome_unknown"}

  # Failures inside the mail transaction (MAIL FROM/RCPT TO/DATA): an SMTP reply
  # is definitive, but a lost or silent connection may follow a handed-over DATA.
  defp classify_error({:send, {:permanent_failure, _host, _reply}}), do: {:error, "smtp_rejected"}
  defp classify_error({:send, {:temporary_failure, _host, _reply}}), do: {:retry, "smtp_temporary_failure", nil}
  defp classify_error({:send, {:network_failure, _host, {:error, :timeout}}}), do: {:unknown, "smtp_timeout"}
  defp classify_error({:send, _uncertain}), do: {:unknown, "smtp_outcome_unknown"}

  # Failures while opening the session (connect/EHLO/STARTTLS/AUTH): nothing was sent yet.
  defp classify_error({type, _failure} = reason) when type in [:no_more_hosts, :retries_exceeded] do
    case session_error_code(reason) do
      code when code in ["smtp_unavailable", "smtp_tls_failed"] -> {:retry, code, nil}
      code -> {:error, code}
    end
  end

  defp classify_error(reason) when reason in [:no_relay, :invalid_port, :no_credentials],
    do: {:error, "smtp_invalid_settings"}

  defp classify_error(_reason), do: {:unknown, "smtp_outcome_unknown"}

  defp session_error_code({_type, {:permanent_failure, _host, :auth_failed}}), do: "smtp_auth_failed"
  defp session_error_code({_type, {:permanent_failure, _host, _reply}}), do: "smtp_rejected"
  defp session_error_code({_type, {:missing_requirement, _host, :tls}}), do: "smtp_tls_unavailable"
  defp session_error_code({_type, {:missing_requirement, _host, :auth}}), do: "smtp_auth_unavailable"
  defp session_error_code({_type, {:temporary_failure, _host, :tls_failed}}), do: "smtp_tls_failed"
  defp session_error_code(_reason), do: "smtp_unavailable"

  defp setting(settings, key), do: Map.get(settings, Atom.to_string(key), Map.get(settings, key))

  defp normalize_host(host) when is_binary(host) do
    case host |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_host(_host), do: nil

  defp timeout_ms(opts), do: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
end
