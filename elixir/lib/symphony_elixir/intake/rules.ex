defmodule SymphonyElixir.Intake.Rules do
  @moduledoc """
  Durable Jira intake rule configuration.

  Rule edits are versioned. Activation is the only operation that enables a
  rule; changing the source or priorities of an active rule disables it and
  requires a new baseline.
  """

  import Ecto.Changeset

  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{AutomationRule, IntegrationConnection, Project}

  @immutable_after_activation ~w(
    project_id
    jira_connection_id
    linear_team_id
    linear_project_id
    linear_todo_state_id
    linear_hold_label_id
    initial_policy
  )a

  @string_attr_keys %{
    "project_id" => :project_id,
    "jira_connection_id" => :jira_connection_id,
    "name" => :name,
    "source_type" => :source_type,
    "source_id" => :source_id,
    "priority_ids" => :priority_ids,
    "interval_seconds" => :interval_seconds,
    "initial_policy" => :initial_policy,
    "linear_team_id" => :linear_team_id,
    "linear_project_id" => :linear_project_id,
    "linear_todo_state_id" => :linear_todo_state_id,
    "linear_hold_label_id" => :linear_hold_label_id,
    "email_connection_id" => :email_connection_id,
    "sms_connection_id" => :sms_connection_id,
    "email_recipients" => :email_recipients,
    "sms_recipients" => :sms_recipients,
    "enabled" => :enabled,
    "config_version" => :config_version,
    "activation_status" => :activation_status,
    "activated_at" => :activated_at,
    "baseline_generation" => :baseline_generation,
    "lease_token" => :lease_token,
    "lease_until" => :lease_until,
    "lock_version" => :lock_version
  }

  @type attrs :: map()

  @spec changeset(AutomationRule.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(%AutomationRule{} = rule, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    rule
    |> AutomationRule.changeset(attrs)
    |> validate_rule_values()
    |> validate_recipients(:email_connection_id, :email_recipients, "email")
    |> validate_recipients(:sms_connection_id, :sms_recipients, "sms")
  end

  @spec create(attrs()) :: {:ok, AutomationRule.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)
    attrs = attrs |> Map.put(:enabled, false) |> Map.put(:activation_status, "idle") |> Map.delete(:activated_at)

    with {:ok, changeset} <- validate_connection_kinds(changeset(%AutomationRule{}, attrs)) do
      Repo.insert(changeset)
    end
  end

  @spec patch(AutomationRule.t(), attrs()) ::
          {:ok, AutomationRule.t()} | {:error, Ecto.Changeset.t() | :immutable_after_activation}
  def patch(%AutomationRule{} = rule, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    if activated?(rule) and immutable_change?(attrs) do
      {:error, :immutable_after_activation}
    else
      attrs =
        attrs
        |> Map.delete(:config_version)
        |> Map.delete(:lock_version)
        |> Map.put(:config_version, rule.config_version + 1)
        |> Map.put(:lock_version, rule.lock_version + 1)
        |> Map.put(:enabled, rule.enabled)
        |> Map.put(:activation_status, rule.activation_status)
        |> disable_for_source_change(rule)

      changeset = changeset(rule, attrs)

      with {:ok, changeset} <- validate_connection_kinds(changeset) do
        Repo.update(changeset)
      end
    end
  end

  @spec activate(AutomationRule.t()) ::
          {:ok, AutomationRule.t()} | {:error, :source_conflict | Ecto.Changeset.t()}
  def activate(%AutomationRule{} = rule) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    changeset =
      rule
      |> changeset(%{
        enabled: true,
        activation_status: "activating",
        activated_at: rule.activated_at || now,
        lock_version: rule.lock_version + 1
      })

    with {:ok, changeset} <- validate_connection_kinds(changeset),
         {:ok, activating} <- Repo.update(changeset) do
      activating
      |> changeset(%{activation_status: "idle", lock_version: activating.lock_version + 1})
      |> Repo.update()
      |> normalize_activation_error()
    else
      {:error, changeset} -> normalize_activation_error({:error, changeset})
    end
  end

  @spec disable(AutomationRule.t()) :: {:ok, AutomationRule.t()} | {:error, Ecto.Changeset.t()}
  def disable(%AutomationRule{} = rule) do
    rule
    |> changeset(%{
      enabled: false,
      activation_status: "idle",
      lease_token: nil,
      lease_until: nil,
      lock_version: rule.lock_version + 1
    })
    |> Repo.update()
  end

  @spec snapshot(AutomationRule.t(), DateTime.t() | nil) :: map()
  def snapshot(%AutomationRule{} = rule, qualified_at \\ nil) do
    qualified_at = qualified_at || DateTime.utc_now() |> DateTime.truncate(:microsecond)
    project = get_record(Project, rule.project_id)
    jira_connection = get_record(IntegrationConnection, rule.jira_connection_id)
    email_connection = get_record(IntegrationConnection, rule.email_connection_id)
    sms_connection = get_record(IntegrationConnection, rule.sms_connection_id)

    %{
      project_id: rule.project_id,
      project_name: project && project.slug,
      jira_connection_id: rule.jira_connection_id,
      jira_connection_name: jira_connection && jira_connection.name,
      name: rule.name,
      source_type: rule.source_type,
      source_id: rule.source_id,
      priority_ids: rule.priority_ids,
      initial_policy: rule.initial_policy,
      linear_team_id: rule.linear_team_id,
      linear_project_id: rule.linear_project_id,
      linear_todo_state_id: rule.linear_todo_state_id,
      linear_hold_label_id: rule.linear_hold_label_id,
      email_connection_id: rule.email_connection_id,
      email_connection_name: email_connection && email_connection.name,
      sms_connection_id: rule.sms_connection_id,
      sms_connection_name: sms_connection && sms_connection.name,
      email_recipients: rule.email_recipients,
      sms_recipients: rule.sms_recipients,
      config_version: rule.config_version,
      qualified_at: DateTime.to_iso8601(qualified_at)
    }
  end

  @spec active?(AutomationRule.t()) :: boolean()
  def active?(%AutomationRule{} = rule), do: rule.enabled or rule.activation_status == "activating"

  defp normalize_activation_error({:ok, rule}), do: {:ok, rule}

  defp normalize_activation_error({:error, %Ecto.Changeset{} = changeset}) do
    if unique_source_error?(changeset), do: {:error, :source_conflict}, else: {:error, changeset}
  end

  defp unique_source_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, metadata}} ->
      metadata[:constraint] == :unique and
        metadata[:constraint_name] == "automation_rules_active_source_index"
    end)
  end

  defp activated?(%AutomationRule{} = rule), do: not is_nil(rule.activated_at)

  defp immutable_change?(attrs) do
    Enum.any?(@immutable_after_activation, &Map.has_key?(attrs, &1))
  end

  defp disable_for_source_change(attrs, %AutomationRule{} = rule) do
    if active?(rule) and source_change?(attrs, rule) do
      attrs
      |> Map.put(:enabled, false)
      |> Map.put(:activation_status, "idle")
      |> Map.put(:baseline_generation, nil)
    else
      attrs
    end
  end

  defp source_change?(attrs, rule) do
    Enum.any?([:source_type, :source_id, :priority_ids], fn key ->
      Map.has_key?(attrs, key) and Map.get(attrs, key) != Map.get(rule, key)
    end)
  end

  defp normalize_attrs(attrs) do
    attrs
    |> atomize_keys()
    |> normalize_source_id()
    |> normalize_recipients(:email_recipients, &normalize_email/1)
    |> normalize_recipients(:sms_recipients, &normalize_phone/1)
  end

  defp atomize_keys(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      key = normalize_attr_key(key)

      if is_atom(key), do: Map.put(acc, key, value), else: acc
    end)
  end

  defp normalize_attr_key(key) when is_atom(key), do: key
  defp normalize_attr_key(key), do: Map.get(@string_attr_keys, key)

  defp normalize_source_id(attrs) do
    case Map.fetch(attrs, :source_id) do
      {:ok, source_id} when is_binary(source_id) -> Map.put(attrs, :source_id, String.trim(source_id))
      _ -> attrs
    end
  end

  defp normalize_recipients(attrs, key, normalizer) do
    case Map.fetch(attrs, key) do
      {:ok, recipients} when is_list(recipients) ->
        Map.put(attrs, key, recipients |> Enum.map(normalizer) |> Enum.reject(&(&1 == "")) |> Enum.uniq())

      _ ->
        attrs
    end
  end

  defp normalize_email(value) when is_binary(value) do
    value = String.trim(value)

    case String.split(value, "@", parts: 2) do
      [local, domain] when local != "" and domain != "" -> local <> "@" <> String.downcase(domain)
      _ -> value
    end
  end

  defp normalize_email(value), do: to_string(value)

  defp normalize_phone(value) when is_binary(value), do: String.trim(value)
  defp normalize_phone(value), do: to_string(value)

  defp validate_recipients(changeset, connection_field, recipient_field, channel) do
    recipients = get_field(changeset, recipient_field)
    connection_id = get_field(changeset, connection_field)

    cond do
      not is_list(recipients) ->
        add_error(changeset, recipient_field, "must be a list")

      length(recipients) > 10 ->
        add_error(changeset, recipient_field, "must contain at most 10 recipients")

      Enum.any?(recipients, &blank?/1) ->
        add_error(changeset, recipient_field, "must not contain blank recipients")

      not is_nil(connection_id) and recipients == [] ->
        add_error(changeset, recipient_field, "requires at least one #{channel} recipient")

      is_nil(connection_id) and recipients != [] ->
        add_error(changeset, connection_field, "is required when recipients are configured")

      true ->
        changeset
    end
  end

  defp validate_rule_values(changeset) do
    priority_ids = get_field(changeset, :priority_ids)

    if is_list(priority_ids) and priority_ids != [] and
         Enum.all?(priority_ids, &(is_binary(&1) and String.trim(&1) != "")) do
      changeset
    else
      add_error(changeset, :priority_ids, "must contain at least one non-empty ID")
    end
  end

  defp validate_connection_kinds(changeset) do
    fields = [
      {:jira_connection_id, "jira_cloud"},
      {:email_connection_id, "smtp"},
      {:sms_connection_id, "smsapi"}
    ]

    changeset = Enum.reduce(fields, changeset, &validate_connection_kind/2)

    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  defp validate_connection_kind({field, expected_kind}, changeset) do
    case get_field(changeset, field) do
      nil ->
        changeset

      connection_id ->
        validate_connection_record(changeset, field, expected_kind, connection_id)
    end
  end

  defp validate_connection_record(changeset, field, expected_kind, connection_id) do
    case Repo.get(IntegrationConnection, connection_id) do
      %IntegrationConnection{kind: ^expected_kind} -> changeset
      %IntegrationConnection{} -> add_error(changeset, field, "must reference a #{expected_kind} connection")
      nil -> changeset
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp get_record(_schema, nil), do: nil
  defp get_record(schema, id), do: Repo.get(schema, id)
end
