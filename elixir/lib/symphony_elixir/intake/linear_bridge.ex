defmodule SymphonyElixir.Intake.LinearBridge do
  @moduledoc """
  Creates and reconciles analysis-only Linear issues from reserved intake UUIDs.

  Every attempt looks up the UUID before a mutation. A timed out or conflicted
  create is reconciled through the same UUID before the outbox may be completed.
  """

  import Ecto.Query

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Repo

  alias SymphonyElixir.Storage.{IntakeCase, IntakeEvent, IntegrationDelivery, Project}

  @protected_label "harmony:analysis-only"
  @max_title_codepoints 255
  @default_timeout_ms 15_000

  @type result ::
          {:ok, %{provider_id: String.t()}}
          | {:retry, String.t(), String.t() | nil}
          | {:error, String.t()}
          | {:unknown, String.t()}

  @spec perform(IntegrationDelivery.t()) :: result()
  def perform(delivery), do: perform(delivery, [])

  @spec perform(IntegrationDelivery.t(), keyword()) :: result()
  def perform(%IntegrationDelivery{operation: "linear_create", case_id: case_id} = delivery, opts)
      when is_binary(case_id) and is_list(opts) do
    perform_create(delivery, case_id, opts)
  rescue
    _exception -> {:unknown, "linear_local_state_unavailable"}
  catch
    :exit, _reason -> {:unknown, "linear_local_state_unavailable"}
  end

  def perform(%IntegrationDelivery{}, _opts), do: {:error, "invalid_linear_create_delivery"}

  defp perform_create(%IntegrationDelivery{} = delivery, case_id, opts) do
    with {:ok, intake_case} <- load_case(case_id),
         :ok <- reserved_uuid_matches(delivery, intake_case),
         {:ok, targets} <- target_ids(intake_case.rule_snapshot),
         {:ok, public_url} <- intake_public_url(),
         {:ok, project} <- load_project(intake_case.project_id),
         {:ok, token} <- project_token(project) do
      client_opts = client_opts(token, opts)

      case Client.fetch_issue_by_id(intake_case.linear_issue_id, client_opts) do
        {:ok, %{} = issue} -> confirm_if_matching(issue, intake_case, targets, public_url, opts)
        {:ok, nil} -> create_after_lookup(intake_case, targets, public_url, client_opts, opts)
        {:error, reason} -> {:unknown, error_code(reason)}
      end
    else
      {:error, code} when is_binary(code) -> {:error, code}
    end
  end

  defp load_case(case_id) do
    case Repo.get(IntakeCase, case_id) do
      %IntakeCase{} = intake_case -> {:ok, intake_case}
      nil -> {:error, "linear_case_not_found"}
    end
  end

  defp reserved_uuid_matches(%IntegrationDelivery{payload: payload}, %IntakeCase{} = intake_case) do
    payload_id = Map.get(payload || %{}, "linear_issue_id") || Map.get(payload || %{}, :linear_issue_id)

    cond do
      not match?({:ok, _uuid}, Ecto.UUID.cast(intake_case.linear_issue_id)) ->
        {:error, "linear_reserved_uuid_invalid"}

      payload_id != intake_case.linear_issue_id ->
        {:error, "linear_reserved_uuid_mismatch"}

      true ->
        :ok
    end
  end

  defp target_ids(snapshot) when is_map(snapshot) do
    targets = %{
      team_id: snapshot_value(snapshot, :linear_team_id),
      project_id: snapshot_value(snapshot, :linear_project_id),
      state_id: snapshot_value(snapshot, :linear_todo_state_id),
      label_id: snapshot_value(snapshot, :linear_hold_label_id)
    }

    cond do
      not Enum.all?(Map.values(targets), &(is_binary(&1) and String.trim(&1) != "")) ->
        {:error, "linear_target_configuration_incomplete"}

      Enum.all?(Map.values(targets), &valid_uuid?/1) ->
        {:ok, targets}

      true ->
        {:error, "linear_target_configuration_invalid"}
    end
  end

  defp target_ids(_snapshot), do: {:error, "linear_target_configuration_incomplete"}

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp intake_public_url do
    case Config.intake_settings().public_url do
      url when is_binary(url) ->
        normalized = String.trim(url)
        uri = URI.parse(normalized)

        if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and
             is_nil(uri.query) and is_nil(uri.fragment) do
          {:ok, String.trim_trailing(normalized, "/")}
        else
          {:error, "invalid_intake_public_url"}
        end

      _missing ->
        {:error, "missing_intake_public_url"}
    end
  rescue
    _exception -> {:error, "invalid_intake_public_url"}
  end

  defp case_url(public_url, intake_case) do
    URI.merge(public_url <> "/", "/cases/jira_#{intake_case.id}") |> URI.to_string()
  end

  defp snapshot_value(snapshot, key) do
    Map.get(snapshot, key) || Map.get(snapshot, Atom.to_string(key))
  end

  defp load_project(project_id) do
    case Repo.get(Project, project_id) do
      %Project{} = project -> {:ok, project}
      nil -> {:error, "linear_project_not_found"}
    end
  end

  defp project_token(%Project{tracker_secret: token}) when is_binary(token) do
    if String.trim(token) != "", do: {:ok, token}, else: global_project_token()
  end

  defp project_token(%Project{}), do: global_project_token()

  defp global_project_token do
    case Config.settings!().tracker.api_key do
      token when is_binary(token) -> if(String.trim(token) != "", do: {:ok, token}, else: {:error, "missing_linear_api_token"})
      _missing -> {:error, "missing_linear_api_token"}
    end
  end

  defp client_opts(token, opts) do
    opts
    |> Keyword.take([:request_fun, :timeout_ms])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Keyword.put(:token, token)
    |> Keyword.put_new(:timeout_ms, @default_timeout_ms)
    |> Keyword.put(:retry, false)
  end

  defp create_after_lookup(intake_case, targets, public_url, client_opts, opts) do
    input = create_input(intake_case, targets, public_url)

    case Client.create_issue(input, client_opts) do
      {:ok, %{"success" => true, "issue" => %{} = issue}} ->
        confirm_if_matching(issue, intake_case, targets, public_url, opts)

      {:ok, _payload} ->
        reconcile_after_create(intake_case, targets, public_url, client_opts, opts, :linear_create_unsuccessful)

      {:error, reason} ->
        reconcile_after_create(intake_case, targets, public_url, client_opts, opts, reason)
    end
  end

  defp reconcile_after_create(intake_case, targets, public_url, client_opts, opts, create_reason) do
    case Client.fetch_issue_by_id(intake_case.linear_issue_id, client_opts) do
      {:ok, %{} = issue} ->
        confirm_if_matching(issue, intake_case, targets, public_url, opts)

      {:ok, nil} ->
        if retryable_create_failure?(create_reason) do
          retry_create_once(intake_case, targets, public_url, client_opts, opts)
        else
          reconciliation_result(create_reason)
        end

      {:error, lookup_reason} ->
        {:unknown, error_code(lookup_reason)}
    end
  end

  defp retry_create_once(intake_case, targets, public_url, client_opts, opts) do
    case Client.create_issue(create_input(intake_case, targets, public_url), client_opts) do
      {:ok, %{"success" => true, "issue" => %{} = issue}} ->
        confirm_if_matching(issue, intake_case, targets, public_url, opts)

      {:ok, _payload} ->
        reconcile_final_create(intake_case, targets, public_url, client_opts, opts, :linear_create_unsuccessful)

      {:error, reason} ->
        reconcile_final_create(intake_case, targets, public_url, client_opts, opts, reason)
    end
  end

  defp reconcile_final_create(intake_case, targets, public_url, client_opts, opts, create_reason) do
    case Client.fetch_issue_by_id(intake_case.linear_issue_id, client_opts) do
      {:ok, %{} = issue} -> confirm_if_matching(issue, intake_case, targets, public_url, opts)
      {:ok, nil} -> {:unknown, error_code(create_reason)}
      {:error, lookup_reason} -> {:unknown, error_code(lookup_reason)}
    end
  end

  defp retryable_create_failure?({:linear_api_request, :transport_error}), do: true
  defp retryable_create_failure?({:linear_api_status, status}) when status in [408, 429], do: true
  defp retryable_create_failure?({:linear_api_status, status}) when is_integer(status) and status >= 500, do: true
  defp retryable_create_failure?(_reason), do: false

  defp reconciliation_result(:linear_create_unsuccessful), do: {:error, "linear_create_unsuccessful"}
  defp reconciliation_result(reason), do: {:unknown, error_code(reason)}

  defp create_input(%IntakeCase{} = intake_case, targets, public_url) do
    %{
      id: intake_case.linear_issue_id,
      teamId: targets.team_id,
      projectId: targets.project_id,
      stateId: targets.state_id,
      title: issue_title(intake_case),
      description: issue_description(intake_case, public_url),
      labelIds: [targets.label_id]
    }
  end

  defp issue_title(%IntakeCase{jira_key: key, title: title}) do
    "[#{key}] #{title || ""}"
    |> truncate_graphemes(@max_title_codepoints)
  end

  defp truncate_graphemes(value, max_codepoints) do
    {graphemes, _count} =
      value
      |> String.graphemes()
      |> Enum.reduce_while({[], 0}, fn grapheme, {kept, count} ->
        next_count = count + String.length(grapheme)

        if next_count <= max_codepoints do
          {:cont, {[grapheme | kept], next_count}}
        else
          {:halt, {kept, count}}
        end
      end)

    graphemes |> Enum.reverse() |> Enum.join()
  end

  defp issue_description(%IntakeCase{} = intake_case, public_url) do
    [
      "Jira: [#{intake_case.jira_key}](#{intake_case.jira_url})",
      "Harmony case: #{intake_case.id}",
      "Priority: #{intake_case.priority_name} (#{intake_case.priority_id})",
      "Tylko analiza; naprawa wymaga zgody w Harmony.",
      "Opis źródłowy:\n\n#{intake_case.description_text || ""}",
      "[Otwórz sprawę w Harmony](#{case_url(public_url, intake_case)})"
    ]
    |> Enum.join("\n\n")
  end

  defp confirm_if_matching(issue, intake_case, targets, _public_url, opts) do
    if matching_issue?(issue, intake_case, targets) do
      persist_confirmation(issue, intake_case, opts)
    else
      {:unknown, "linear_issue_identity_mismatch"}
    end
  end

  defp matching_issue?(issue, intake_case, targets) do
    issue_identity_matches?(issue, intake_case) and
      issue_targets_match?(issue, targets) and
      issue_has_analysis_marker?(issue, intake_case, targets)
  end

  defp issue_identity_matches?(issue, intake_case) do
    is_binary(issue["id"]) and issue["id"] == intake_case.linear_issue_id and
      nonempty_string?(issue["identifier"]) and nonempty_string?(issue["url"])
  end

  defp issue_targets_match?(issue, targets) do
    get_in(issue, ["team", "id"]) == targets.team_id and
      get_in(issue, ["project", "id"]) == targets.project_id and
      get_in(issue, ["state", "id"]) == targets.state_id and
      get_in(issue, ["state", "name"]) == "Todo"
  end

  defp issue_has_analysis_marker?(issue, intake_case, targets) do
    labels = get_in(issue, ["labels", "nodes"])
    description = issue["description"]

    is_list(labels) and has_protected_label?(labels, targets.label_id) and
      is_binary(description) and String.contains?(description, "Harmony case: #{intake_case.id}") and
      harmony_case_link?(description, intake_case.id)
  end

  defp has_protected_label?(labels, label_id) do
    Enum.any?(labels, &(&1["id"] == label_id and &1["name"] == @protected_label))
  end

  defp harmony_case_link?(description, case_id) do
    expected_path = "/cases/jira_#{case_id}"

    description
    |> then(&Regex.scan(~r/\]\((https:\/\/[^)\s]+)\)/, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.any?(fn url ->
      uri = URI.parse(url)

      uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
        is_nil(uri.userinfo) and uri.path == expected_path and is_nil(uri.query) and
        is_nil(uri.fragment)
    end)
  rescue
    _exception -> false
  end

  defp persist_confirmation(issue, intake_case, opts) do
    now = current_time(opts)

    case Repo.transaction(fn -> persist_locked_confirmation(intake_case, issue, now) end) do
      {:ok, :ok} -> {:ok, %{provider_id: issue["id"]}}
      {:error, _reason} -> {:unknown, "linear_confirmation_persistence_failed"}
    end
  rescue
    _exception -> {:unknown, "linear_confirmation_persistence_failed"}
  end

  defp persist_locked_confirmation(intake_case, issue, now) do
    locked_case =
      Repo.one(
        from(c in IntakeCase,
          where: c.id == ^intake_case.id,
          lock: "FOR UPDATE"
        )
      )

    case locked_case do
      %IntakeCase{linear_issue_id: reserved_id} = current when reserved_id == intake_case.linear_issue_id ->
        confirm_locked_case(current, issue, now)

      _missing_or_changed ->
        Repo.rollback(:linear_reserved_uuid_changed)
    end
  end

  defp confirm_locked_case(%IntakeCase{} = intake_case, issue, now) do
    if confirmed_issue_unchanged?(intake_case, issue) do
      :ok
    else
      first_confirmation? = is_nil(intake_case.linear_confirmed_at)

      intake_case
      |> IntakeCase.changeset(%{
        linear_identifier: issue["identifier"],
        linear_url: issue["url"],
        linear_state_name: get_in(issue, ["state", "name"]),
        linear_confirmed_at: intake_case.linear_confirmed_at || now,
        lock_version: intake_case.lock_version + 1
      })
      |> Repo.update!()

      if first_confirmation? do
        %IntakeEvent{}
        |> IntakeEvent.changeset(%{
          case_id: intake_case.id,
          rule_id: intake_case.rule_id,
          type: "linear_issue_confirmed",
          payload: %{linear_issue_id: issue["id"], identifier: issue["identifier"], url: issue["url"]},
          actor: "system",
          occurred_at: now
        })
        |> Repo.insert!()
      end

      :ok
    end
  end

  defp confirmed_issue_unchanged?(%IntakeCase{} = intake_case, issue) do
    not is_nil(intake_case.linear_confirmed_at) and
      intake_case.linear_identifier == issue["identifier"] and
      intake_case.linear_url == issue["url"] and
      intake_case.linear_state_name == get_in(issue, ["state", "name"])
  end

  defp current_time(opts) do
    case Keyword.get(opts, :clock) do
      fun when is_function(fun, 0) -> fun.()
      %DateTime{} = now -> now
      _missing -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp error_code(:linear_graphql_errors), do: "linear_graphql_errors"
  defp error_code(:linear_unknown_payload), do: "linear_unknown_payload"
  defp error_code({:linear_api_status, status}), do: "linear_http_#{status}"
  defp error_code({:linear_api_request, :transport_error}), do: "linear_transport_error"
  defp error_code(:missing_linear_api_token), do: "missing_linear_api_token"
  defp error_code(_reason), do: "linear_request_failed"

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
