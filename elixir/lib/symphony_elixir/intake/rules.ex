defmodule SymphonyElixir.Intake.Rules do
  @moduledoc """
  Durable Jira intake rule configuration.

  Rule edits are versioned. Activation is the only operation that enables a
  rule; changing the source or priorities of an active rule disables it and
  requires a new baseline.
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2, where: 3]

  alias SymphonyElixir.Intake
  alias SymphonyElixir.Notifications.Smsapi
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
    |> validate_jira_ids()
    |> validate_recipients(:email_connection_id, :email_recipients, "email")
    |> validate_recipients(:sms_connection_id, :sms_recipients, "sms")
    |> validate_phone_recipients()
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

  @doc """
  Activates a rule. `:priority_ranking` stores the Jira priority IDs in the
  order of the Jira response, read by the activation check; without it the
  stored ranking is kept.
  """
  @spec activate(AutomationRule.t(), keyword()) ::
          {:ok, AutomationRule.t()} | {:error, :effects_disabled | :source_conflict | Ecto.Changeset.t()}
  def activate(%AutomationRule{} = rule, opts \\ []) do
    with :ok <- ensure_effects_enabled() do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      baseline_ready? = not is_nil(rule.baseline_generation) and not is_nil(rule.baseline_complete_at)

      changeset =
        rule
        |> changeset(%{
          enabled: baseline_ready?,
          activation_status: if(baseline_ready?, do: "idle", else: "activating"),
          activated_at: rule.activated_at || now,
          priority_ranking: Keyword.get(opts, :priority_ranking, rule.priority_ranking),
          lock_version: rule.lock_version + 1
        })

      with {:ok, changeset} <- validate_connection_kinds(changeset),
           :ok <- ensure_effects_enabled() do
        Repo.update(changeset) |> normalize_activation_error()
      end
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
      priority_ranking: rule.priority_ranking,
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

  @spec fetch(term()) :: {:ok, AutomationRule.t()} | {:error, :not_found}
  def fetch(rule_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(rule_id),
         %AutomationRule{} = rule <- Repo.get(AutomationRule, uuid) do
      {:ok, rule}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc """
  One page of rules ordered by `(inserted_at, id)`, optionally for one project.
  `:after` is the `{inserted_at, id}` of the last row of the previous page.
  """
  @spec list_page(keyword()) :: [AutomationRule.t()]
  def list_page(opts) do
    limit = Keyword.fetch!(opts, :limit)

    from(rule in AutomationRule, order_by: [asc: rule.inserted_at, asc: rule.id], limit: ^limit)
    |> maybe_project(Keyword.get(opts, :project_id))
    |> after_position(Keyword.get(opts, :after))
    |> Repo.all()
  end

  @doc "Rule IDs in scope of a bulk \"check now\", optionally for one project."
  @spec list_ids(binary() | nil) :: [binary()]
  def list_ids(project_id) do
    from(rule in AutomationRule, order_by: [asc: rule.inserted_at, asc: rule.id], select: rule.id)
    |> maybe_project(project_id)
    |> Repo.all()
  end

  @doc """
  Applies a partial edit when `version` is the current `config_version`.
  Background scans change only `lock_version`, so they never make an open
  form stale.
  """
  @spec patch_versioned(binary(), pos_integer(), attrs()) ::
          {:ok, AutomationRule.t()}
          | {:error, :not_found | :stale_version | :immutable_after_activation | Ecto.Changeset.t()}
  def patch_versioned(rule_id, version, attrs), do: with_config_version(rule_id, version, &patch(&1, attrs))

  @spec activate_versioned(binary(), pos_integer(), keyword()) ::
          {:ok, AutomationRule.t()}
          | {:error, :not_found | :stale_version | :effects_disabled | :source_conflict | Ecto.Changeset.t()}
  def activate_versioned(rule_id, version, opts \\ []),
    do: with_config_version(rule_id, version, &activate(&1, opts))

  @spec pause_versioned(binary(), pos_integer()) ::
          {:ok, AutomationRule.t()} | {:error, :not_found | :stale_version | Ecto.Changeset.t()}
  def pause_versioned(rule_id, version), do: with_config_version(rule_id, version, &disable/1)

  defp with_config_version(rule_id, version, fun) do
    Repo.transaction(fn ->
      case Repo.one(from(rule in AutomationRule, where: rule.id == ^rule_id, lock: "FOR UPDATE")) do
        nil -> Repo.rollback(:not_found)
        %AutomationRule{config_version: ^version} = rule -> unwrap_or_rollback(fun.(rule))
        %AutomationRule{} -> Repo.rollback(:stale_version)
      end
    end)
  end

  defp unwrap_or_rollback({:ok, rule}), do: rule
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp maybe_project(query, nil), do: query
  defp maybe_project(query, project_id), do: where(query, [rule], rule.project_id == ^project_id)

  defp after_position(query, nil), do: query

  defp after_position(query, {inserted_at, id}) do
    where(query, [rule], rule.inserted_at > ^inserted_at or (rule.inserted_at == ^inserted_at and rule.id > ^id))
  end

  defp normalize_activation_error({:ok, rule}), do: {:ok, rule}

  defp normalize_activation_error({:error, %Ecto.Changeset{} = changeset}) do
    if unique_source_error?(changeset), do: {:error, :source_conflict}, else: {:error, changeset}
  end

  defp ensure_effects_enabled do
    if Intake.effects_enabled?(), do: :ok, else: {:error, :effects_disabled}
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
      |> Map.put(:baseline_complete_at, nil)
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

  # A number that is not valid E.164 is kept as typed so validation rejects it.
  defp normalize_phone(value) when is_binary(value) do
    case Smsapi.normalize_phone(value) do
      {:ok, e164} -> e164
      {:error, _code} -> String.trim(value)
    end
  end

  defp normalize_phone(value), do: value |> to_string() |> normalize_phone()

  # Only a changed list is checked, so legacy rows can still be disabled.
  defp validate_phone_recipients(changeset) do
    validate_change(changeset, :sms_recipients, fn :sms_recipients, recipients ->
      if Enum.all?(recipients, &(Smsapi.normalize_phone(&1) == {:ok, &1})) do
        []
      else
        [sms_recipients: "must contain E.164 phone numbers"]
      end
    end)
  end

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

  # Jira IDs are interpolated into JQL, so only plain digits are accepted.
  defp validate_jira_ids(changeset) do
    changeset
    |> validate_format(:source_id, ~r/\A[0-9]+\z/, message: "must contain only digits")
    |> validate_change(:priority_ids, fn :priority_ids, ids -> priority_id_errors(ids) end)
  end

  defp priority_id_errors(ids) when is_list(ids) do
    cond do
      length(ids) > 100 -> [priority_ids: "must contain at most 100 IDs"]
      not Enum.all?(ids, &(is_binary(&1) and Regex.match?(~r/\A[0-9]+\z/, &1))) -> [priority_ids: "must contain only digits"]
      length(Enum.uniq(ids)) != length(ids) -> [priority_ids: "must not contain duplicates"]
      true -> []
    end
  end

  defp priority_id_errors(_ids), do: []

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
