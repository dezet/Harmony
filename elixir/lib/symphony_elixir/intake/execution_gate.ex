defmodule SymphonyElixir.Intake.ExecutionGate do
  @moduledoc """
  Prevents imported Linear issues from entering implementation runs without
  durable approval for the current intake analysis.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.IntakeCase

  @protected_label "harmony:analysis-only"

  @type denial_reason ::
          :invalid_issue
          | :incomplete_case
          | :analysis_only
          | :stale_approval
          | :unlinked_managed_issue
          | :project_mismatch
          | :database_unavailable

  @spec authorize_implementation(Issue.t(), String.t() | nil) ::
          :ok | {:error, denial_reason()}
  def authorize_implementation(issue, project_id), do: authorize_implementation(issue, project_id, [])

  @spec authorize_implementation(Issue.t(), String.t() | nil, keyword()) ::
          :ok | {:error, denial_reason()}
  def authorize_implementation(%Issue{id: id, labels: labels, description: description} = issue, project_id, opts)
      when is_binary(id) and id != "" and is_list(labels) and is_list(opts) and
             (is_binary(description) or is_nil(description)) do
    if Enum.any?(labels, &(not is_binary(&1))) do
      {:error, :invalid_issue}
    else
      cond do
        not valid_uuid?(id) ->
          if managed_marker?(issue), do: {:error, :unlinked_managed_issue}, else: :ok

        true ->
          with {:ok, intake_case} <- find_case(id, opts) do
            authorize_case(intake_case, project_id, issue)
          else
            :not_found ->
              if managed_marker?(issue), do: {:error, :unlinked_managed_issue}, else: :ok

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  def authorize_implementation(_issue, _project_id, _opts), do: {:error, :invalid_issue}

  defp find_case(issue_id, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    try do
      case repo.get_by(IntakeCase, linear_issue_id: issue_id) do
        %IntakeCase{} = intake_case ->
          {:ok, intake_case}

        nil ->
          :not_found

        _other ->
          {:error, :database_unavailable}
      end
    rescue
      _exception -> {:error, :database_unavailable}
    catch
      _kind, _reason -> {:error, :database_unavailable}
    end
  end

  defp authorize_case(
         %IntakeCase{
           project_id: case_project_id,
           analysis_version: analysis_version,
           repair_approved_at: approved_at,
           repair_approved_version: approved_version
         },
         project_id,
         _issue
       )
       when is_binary(case_project_id) and is_integer(analysis_version) do
    cond do
      not is_binary(project_id) or project_id != case_project_id ->
        {:error, :project_mismatch}

      is_nil(approved_at) or is_nil(approved_version) ->
        {:error, :analysis_only}

      approved_version != analysis_version ->
        {:error, :stale_approval}

      true ->
        :ok
    end
  end

  defp authorize_case(_intake_case, _project_id, _issue), do: {:error, :incomplete_case}

  defp valid_uuid?(id), do: match?({:ok, _uuid}, Ecto.UUID.cast(id))

  defp managed_marker?(%Issue{labels: labels, description: description}) do
    protected_label? = is_list(labels) and Enum.any?(labels, &(String.downcase(&1) == @protected_label))
    description_marker? = is_binary(description) and description_has_marker?(description)
    protected_label? or description_marker?
  end

  defp description_has_marker?(description) do
    Regex.match?(~r|\bharmony(?:\s+intake)?\s+case(?:\s+id)?\s*[:#]|i, description) or
      Regex.match?(~r|/cases/jira_[0-9a-fA-F-]{36}|i, description)
  end
end
