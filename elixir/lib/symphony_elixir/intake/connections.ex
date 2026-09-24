defmodule SymphonyElixir.Intake.Connections do
  @moduledoc """
  Configuration and safe presentation of durable intake connections.

  Secrets are accepted for writes only. The presenter deliberately exposes a
  set/unset marker instead of the encrypted value. A saved connection is
  announced on `intake:workspace` after commit, without any of its values.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias SymphonyElixir.Config
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{AutomationRule, IntakeCase, IntakeEvent, IntegrationConnection}
  alias SymphonyElixirWeb.IntakePubSub

  @input_settings %{
    "smtp" => ~w(host port tls_mode username from_email from_name message_id_domain),
    "jira_cloud" => ~w(site_url auth_mode account_email cloud_id),
    "smsapi" => ~w(sender)
  }
  @setting_error_keys @input_settings
                      |> Map.values()
                      |> List.flatten()
                      |> Map.new(&{&1, String.to_atom("settings." <> &1)})
  @default_smtp_port 587
  @address_pattern ~r/\A[A-Za-z0-9._%+'-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+\z/
  @domain_pattern ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+\z/
  @atlassian_host ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.atlassian\.net\z/
  @uuid_pattern ~r/\A[a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}\z/

  @known_attr_keys ~w(kind name settings secret clear_secret secret_version enabled last_checked_at health error_code lock_version)a
  @known_string_keys Map.new(@known_attr_keys, &{Atom.to_string(&1), &1})

  @type attrs :: map()
  @type presented :: %{
          id: binary(),
          kind: String.t(),
          name: String.t(),
          settings: map(),
          secret_status: String.t(),
          enabled: boolean(),
          health: String.t(),
          error_code: String.t() | nil,
          last_checked_at: DateTime.t() | nil,
          lock_version: pos_integer()
        }

  @spec changeset(IntegrationConnection.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(%IntegrationConnection{} = connection, attrs) when is_map(attrs) do
    {attrs, contains_secret_settings?} = normalize_attrs(attrs)
    changeset_for_attrs(connection, attrs, contains_secret_settings?)
  end

  @spec create(attrs()) :: {:ok, IntegrationConnection.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %IntegrationConnection{}
    |> changeset(attrs)
    |> Repo.insert()
    |> announce()
  end

  @spec update(IntegrationConnection.t(), attrs()) ::
          {:ok, IntegrationConnection.t()} | {:error, Ecto.Changeset.t()}
  def update(%IntegrationConnection{} = connection, attrs) when is_map(attrs) do
    connection
    |> update_changeset(attrs)
    |> Repo.update()
    |> announce()
  end

  @doc """
  Creates a connection from API `ConnectionInput`, validating the provider
  settings strictly (spec §7.2, §10.2, §10.3, §12). New connections are
  disabled unless the input enables them explicitly.
  """
  @spec create_input(attrs()) :: {:ok, IntegrationConnection.t()} | {:error, Ecto.Changeset.t()}
  def create_input(attrs) when is_map(attrs) do
    kind = Map.get(attrs, "kind")

    attrs =
      attrs
      |> Map.put("settings", input_settings_defaults(kind, Map.get(attrs, "settings")))
      |> Map.put_new("enabled", false)

    %IntegrationConnection{}
    |> changeset(attrs)
    |> validate_input()
    |> Repo.insert()
    |> announce()
  end

  @doc """
  Applies an API edit when `version` is the current `lock_version`.

  A blank secret keeps the stored one. `clear_secret: true` removes it,
  disables the connection and disables every rule activation that depends
  on it, in one transaction.
  """
  @spec update_input(binary(), pos_integer(), attrs()) ::
          {:ok, IntegrationConnection.t()} | {:error, :not_found | :stale_version | Ecto.Changeset.t()}
  def update_input(connection_id, version, attrs) when is_map(attrs) do
    clear_secret? = Map.get(attrs, "clear_secret") == true

    IntakePubSub.transaction(fn ->
      connection = Repo.one(from(c in IntegrationConnection, where: c.id == ^connection_id, lock: "FOR UPDATE"))

      cond do
        is_nil(connection) -> Repo.rollback(:not_found)
        connection.lock_version != version -> Repo.rollback(:stale_version)
        true -> persist_input_update(connection, attrs, clear_secret?)
      end
    end)
  end

  @doc "Stores the result of a read-only connection test without bumping `lock_version`."
  @spec record_check(IntegrationConnection.t(), :ok | {:error, String.t()}, DateTime.t()) :: IntegrationConnection.t()
  def record_check(%IntegrationConnection{} = connection, result, %DateTime{} = checked_at) do
    {health, error_code} =
      case result do
        :ok -> {"ok", nil}
        {:error, code} -> {"error", code}
      end

    changes = [health: health, error_code: error_code, last_checked_at: checked_at]
    {1, _rows} = Repo.update_all(from(c in IntegrationConnection, where: c.id == ^connection.id), set: changes)
    :ok = IntakePubSub.track_config()
    struct(connection, changes)
  end

  @spec fetch(term()) :: {:ok, IntegrationConnection.t()} | {:error, :not_found}
  def fetch(connection_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(connection_id),
         %IntegrationConnection{} = connection <- Repo.get(IntegrationConnection, uuid) do
      {:ok, connection}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc "One page of connections ordered by `(inserted_at, id)`."
  @spec list_page(keyword()) :: [IntegrationConnection.t()]
  def list_page(opts) do
    limit = Keyword.fetch!(opts, :limit)

    from(c in IntegrationConnection, order_by: [asc: c.inserted_at, asc: c.id], limit: ^limit)
    |> after_position(Keyword.get(opts, :after))
    |> Repo.all()
  end

  defp after_position(query, nil), do: query

  defp after_position(query, {inserted_at, id}) do
    where(query, [c], c.inserted_at > ^inserted_at or (c.inserted_at == ^inserted_at and c.id > ^id))
  end

  defp update_changeset(connection, attrs) do
    clear_secret? = Map.get(attrs, :clear_secret, Map.get(attrs, "clear_secret", false)) == true
    {attrs, contains_secret_settings?} = normalize_attrs(attrs)
    attrs = merge_settings(attrs, connection)

    connection
    |> changeset_for_attrs(attrs, contains_secret_settings?)
    |> force_secret_clear(clear_secret?)
    |> reject_used_site_url_change(connection)
  end

  defp persist_input_update(connection, attrs, clear_secret?) do
    attrs =
      attrs
      |> Map.put("lock_version", connection.lock_version + 1)
      |> then(&if(clear_secret?, do: Map.put(&1, "enabled", false), else: &1))

    case connection |> update_changeset(attrs) |> validate_input() |> Repo.update() do
      {:ok, updated} ->
        if clear_secret?, do: disable_dependent_rules(updated)
        :ok = IntakePubSub.track_config()
        updated

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp disable_dependent_rules(%IntegrationConnection{id: id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rules =
      Repo.all(
        from(rule in AutomationRule,
          where: rule.jira_connection_id == ^id or rule.email_connection_id == ^id or rule.sms_connection_id == ^id,
          where: rule.enabled or rule.activation_status == "activating",
          lock: "FOR UPDATE",
          select: %{id: rule.id, project_id: rule.project_id}
        )
      )

    rule_ids = Enum.map(rules, & &1.id)

    Repo.update_all(from(rule in AutomationRule, where: rule.id in ^rule_ids),
      set: [enabled: false, activation_status: "idle", lease_token: nil, lease_until: nil, updated_at: now],
      inc: [lock_version: 1]
    )

    Enum.each(rules, &IntakePubSub.track(%{project_id: &1.project_id, rule_id: &1.id}))

    Enum.each(rule_ids, fn rule_id ->
      %IntakeEvent{}
      |> IntakeEvent.changeset(%{
        rule_id: rule_id,
        type: "rule_disabled",
        payload: %{"reason" => "connection_secret_cleared", "connection_id" => id},
        actor: "operator",
        occurred_at: now
      })
      |> Repo.insert!()
    end)
  end

  defp announce({:ok, %IntegrationConnection{}} = result) do
    :ok = IntakePubSub.track_config()
    result
  end

  defp announce(result), do: result

  defp input_settings_defaults("smtp", settings) when is_map(settings) do
    settings
    |> Map.put_new("port", @default_smtp_port)
    |> Map.put_new("from_name", "Harmony")
  end

  defp input_settings_defaults(_kind, settings), do: settings

  defp validate_input(changeset) do
    kind = get_field(changeset, :kind)
    settings = get_field(changeset, :settings)

    changeset
    |> validate_input_settings(kind, settings)
    |> validate_enabled_secret()
  end

  defp validate_enabled_secret(changeset) do
    if get_field(changeset, :enabled) == true and is_nil(get_field(changeset, :secret)) do
      add_error(changeset, :enabled, "requires a stored secret")
    else
      changeset
    end
  end

  defp validate_input_settings(changeset, kind, settings) when is_map_key(@input_settings, kind) and is_map(settings) do
    allowed = Map.fetch!(@input_settings, kind)
    settings = Map.new(settings, fn {key, value} -> {to_string(key), value} end)

    changeset =
      case settings |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort() do
        [] -> changeset
        unknown -> add_error(changeset, :settings, "unsupported settings: " <> Enum.join(unknown, ", "))
      end

    kind
    |> provider_setting_errors(settings)
    |> Enum.reduce(changeset, fn {key, message}, acc -> add_error(acc, Map.fetch!(@setting_error_keys, key), message) end)
  end

  defp validate_input_settings(changeset, _kind, _settings), do: changeset

  defp provider_setting_errors("smtp", settings) do
    [
      check(settings, "host", &allowed_smtp_host?/1, "must be listed in intake.smtp_allowed_hosts"),
      check(settings, "port", &(is_integer(&1) and &1 in 1..65_535), "must be an integer between 1 and 65535"),
      check(settings, "tls_mode", &(&1 in ["starttls", "tls"]), "must be starttls or tls"),
      check(settings, "username", &plain_text?/1, "must be a non-empty single line"),
      check(settings, "from_email", &address?/1, "must be an e-mail address"),
      check(settings, "from_name", &plain_text?/1, "must be a non-empty single line"),
      check(settings, "message_id_domain", &(is_binary(&1) and Regex.match?(@domain_pattern, &1)), "must be a domain name")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp provider_setting_errors("jira_cloud", settings) do
    auth_errors =
      case Map.get(settings, "auth_mode") do
        "classic" -> [check(settings, "account_email", &address?/1, "is required for classic authentication")]
        "scoped" -> [check(settings, "cloud_id", &(is_binary(&1) and Regex.match?(@uuid_pattern, &1)), "must be the Atlassian cloud ID")]
        _other -> [{"auth_mode", "must be classic or scoped"}]
      end

    [check(settings, "site_url", &atlassian_site_url?/1, "must be https://<site>.atlassian.net") | auth_errors]
    |> Enum.reject(&is_nil/1)
  end

  defp provider_setting_errors("smsapi", settings) do
    [check(settings, "sender", &(plain_text?(&1) and String.length(&1) <= 11), "must be an approved sender name of up to 11 characters")]
    |> Enum.reject(&is_nil/1)
  end

  defp check(settings, key, valid?, message) do
    if valid?.(Map.get(settings, key)), do: nil, else: {key, message}
  end

  defp allowed_smtp_host?(host) when is_binary(host) do
    normalized = host |> String.trim() |> String.downcase()
    allowed = Enum.map(Config.intake_settings().smtp_allowed_hosts, &(&1 |> String.trim() |> String.downcase()))
    normalized != "" and normalized in allowed
  end

  defp allowed_smtp_host?(_host), do: false

  defp atlassian_site_url?(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    uri.scheme == "https" and is_binary(uri.host) and Regex.match?(@atlassian_host, uri.host) and is_nil(uri.userinfo) and
      is_nil(uri.query) and is_nil(uri.fragment) and uri.path in [nil, "", "/"] and uri.port in [nil, 443]
  end

  defp atlassian_site_url?(_url), do: false

  defp address?(value), do: is_binary(value) and Regex.match?(@address_pattern, value)

  defp plain_text?(value) when is_binary(value),
    do: String.trim(value) != "" and String.valid?(value) and not Regex.match?(~r/[\x00-\x1F\x7F]/, value)

  defp plain_text?(_value), do: false

  @spec present(IntegrationConnection.t()) :: presented()
  def present(%IntegrationConnection{} = connection) do
    %{
      id: connection.id,
      kind: connection.kind,
      name: connection.name,
      settings: redact_settings(connection.settings || %{}),
      secret_status: if(is_nil(connection.secret), do: "unset", else: "set"),
      enabled: connection.enabled,
      health: connection.health,
      error_code: connection.error_code,
      last_checked_at: connection.last_checked_at,
      lock_version: connection.lock_version
    }
  end

  @spec secret_set?(IntegrationConnection.t()) :: boolean()
  def secret_set?(%IntegrationConnection{} = connection), do: not is_nil(connection.secret)

  @spec site_url(IntegrationConnection.t()) :: String.t() | nil
  def site_url(%IntegrationConnection{} = connection) do
    get_in(connection.settings || %{}, ["site_url"]) ||
      get_in(connection.settings || %{}, [:site_url])
  end

  defp normalize_attrs(attrs) do
    attrs = atomize_known_keys(attrs)
    {attrs, contains_secret_settings?} = normalize_settings(attrs)

    attrs =
      cond do
        Map.get(attrs, :clear_secret, false) == true ->
          attrs
          |> Map.delete(:clear_secret)
          |> Map.put(:secret, nil)

        blank_secret?(Map.get(attrs, :secret, :missing)) ->
          Map.delete(attrs, :secret)
          |> Map.delete(:clear_secret)

        true ->
          Map.delete(attrs, :clear_secret)
      end

    {attrs, contains_secret_settings?}
  end

  defp atomize_known_keys(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      normalized_key = if is_atom(key), do: key, else: Map.get(@known_string_keys, key)

      if is_nil(normalized_key), do: acc, else: Map.put(acc, normalized_key, value)
    end)
  end

  defp blank_secret?(:missing), do: true
  defp blank_secret?(nil), do: true
  defp blank_secret?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_secret?(_value), do: false

  defp force_secret_clear(changeset, true), do: put_change(changeset, :secret, nil)
  defp force_secret_clear(changeset, false), do: changeset

  defp merge_settings(attrs, %IntegrationConnection{settings: current_settings}) do
    {safe_current_settings, current_has_secrets?} = sanitize_settings(current_settings || %{})

    case Map.get(attrs, :settings) do
      settings when is_map(settings) ->
        Map.put(attrs, :settings, Map.merge(safe_current_settings, settings))

      _ when current_has_secrets? ->
        Map.put(attrs, :settings, safe_current_settings)

      _ ->
        attrs
    end
  end

  defp normalize_settings(attrs) do
    case Map.get(attrs, :settings) do
      settings when is_map(settings) ->
        {safe_settings, contains_secret_settings?} = sanitize_settings(settings)
        {Map.put(attrs, :settings, safe_settings), contains_secret_settings?}

      _ ->
        {attrs, false}
    end
  end

  defp sanitize_settings(settings) when is_map(settings) do
    Enum.reduce(settings, {%{}, false}, fn {key, value}, {safe_settings, found_secret?} ->
      key = to_string(key)

      if secret_setting_key?(key) do
        {safe_settings, true}
      else
        {safe_value, nested_secret?} = sanitize_settings(value)
        {Map.put(safe_settings, key, safe_value), found_secret? or nested_secret?}
      end
    end)
  end

  defp sanitize_settings(values) when is_list(values) do
    Enum.map_reduce(values, false, fn value, found_secret? ->
      {safe_value, nested_secret?} = sanitize_settings(value)
      {safe_value, found_secret? or nested_secret?}
    end)
  end

  defp sanitize_settings(value), do: {value, false}

  defp changeset_for_attrs(connection, attrs, contains_secret_settings?) do
    changeset =
      connection
      |> IntegrationConnection.changeset(attrs)
      |> validate_connection_settings()

    if contains_secret_settings? do
      add_error(changeset, :settings, "must not contain credentials; provide them using the encrypted secret field")
    else
      changeset
    end
  end

  defp validate_connection_settings(changeset) do
    changeset
    |> validate_change(:name, fn :name, name ->
      if is_binary(name) and String.trim(name) != "" do
        []
      else
        [name: "must not be blank"]
      end
    end)
    |> validate_change(:settings, fn :settings, settings ->
      case get_field(changeset, :kind) do
        "jira_cloud" -> validate_jira_settings(settings)
        "smtp" -> validate_smtp_settings(settings)
        "smsapi" -> validate_sms_settings(settings)
        _ -> []
      end
    end)
  end

  defp validate_jira_settings(settings) when is_map(settings) do
    case settings_value(settings, :site_url) do
      site_url when is_binary(site_url) ->
        uri = URI.parse(String.trim(site_url))

        if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" do
          []
        else
          [site_url: "must be an HTTPS URL"]
        end

      _ ->
        [site_url: "is required"]
    end
  end

  defp validate_jira_settings(_settings), do: [settings: "must be a map"]

  defp validate_smtp_settings(settings) when is_map(settings) do
    if blank?(settings_value(settings, :host)) do
      [settings: "host is required"]
    else
      []
    end
  end

  defp validate_smtp_settings(_settings), do: [settings: "must be a map"]

  defp validate_sms_settings(settings) when is_map(settings) do
    if blank?(settings_value(settings, :sender)) do
      [settings: "sender is required"]
    else
      []
    end
  end

  defp validate_sms_settings(_settings), do: [settings: "must be a map"]

  defp settings_value(settings, key) do
    Map.get(settings, key) || Map.get(settings, Atom.to_string(key))
  end

  defp redact_settings(settings) when is_map(settings) do
    Enum.reduce(settings, %{}, fn {key, value}, acc ->
      if secret_setting_key?(key) do
        acc
      else
        Map.put(acc, key, redact_settings(value))
      end
    end)
  end

  defp redact_settings(values) when is_list(values), do: Enum.map(values, &redact_settings/1)
  defp redact_settings(value), do: value

  defp secret_setting_key?(key) do
    normalized_key = key |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

    Enum.any?(["secret", "token", "password", "credential", "apikey", "authorization", "privatekey"], fn marker ->
      String.contains?(normalized_key, marker)
    end)
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp reject_used_site_url_change(changeset, %IntegrationConnection{} = connection) do
    if connection.kind == "jira_cloud" and site_url_changed?(changeset, connection) and used?(connection) do
      add_error(changeset, :site_url, "cannot change after the connection has been used")
    else
      changeset
    end
  end

  defp site_url_changed?(changeset, connection) do
    case get_change(changeset, :settings) do
      nil -> false
      settings -> settings_value(settings, :site_url) != site_url(connection)
    end
  end

  defp used?(%IntegrationConnection{} = connection) do
    not is_nil(connection.last_checked_at) or
      Repo.exists?(from(rule in AutomationRule, where: rule.jira_connection_id == ^connection.id)) or
      Repo.exists?(from(intake_case in IntakeCase, where: intake_case.jira_connection_id == ^connection.id))
  end
end
