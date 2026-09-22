defmodule SymphonyElixir.Intake.Connections do
  @moduledoc """
  Configuration and safe presentation of durable intake connections.

  Secrets are accepted for writes only. The presenter deliberately exposes a
  set/unset marker instead of the encrypted value.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{AutomationRule, IntakeCase, IntegrationConnection}

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
  end

  @spec update(IntegrationConnection.t(), attrs()) ::
          {:ok, IntegrationConnection.t()} | {:error, Ecto.Changeset.t()}
  def update(%IntegrationConnection{} = connection, attrs) when is_map(attrs) do
    clear_secret? = Map.get(attrs, :clear_secret, Map.get(attrs, "clear_secret", false)) == true
    {attrs, contains_secret_settings?} = normalize_attrs(attrs)
    attrs = merge_settings(attrs, connection)

    connection
    |> changeset_for_attrs(attrs, contains_secret_settings?)
    |> force_secret_clear(clear_secret?)
    |> reject_used_site_url_change(connection)
    |> Repo.update()
  end

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
      normalized_key =
        case key do
          "kind" -> :kind
          "name" -> :name
          "settings" -> :settings
          "secret" -> :secret
          "clear_secret" -> :clear_secret
          "secret_version" -> :secret_version
          "enabled" -> :enabled
          "last_checked_at" -> :last_checked_at
          "health" -> :health
          "error_code" -> :error_code
          "lock_version" -> :lock_version
          atom when is_atom(atom) -> atom
          other -> other
        end

      if is_atom(normalized_key), do: Map.put(acc, normalized_key, value), else: acc
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
