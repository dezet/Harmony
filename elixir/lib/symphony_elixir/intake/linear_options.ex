defmodule SymphonyElixir.Intake.LinearOptions do
  @moduledoc """
  Linear targets for a rule form, read with the project's own Linear token:
  teams, projects, workflow states with the exact `Todo` state, and the
  analysis-only hold label. Every value is an explicit Linear ID.

  `ensure_hold_label/3` reuses a label with the exact hold name and creates it
  only when the team has none. The create is never retried automatically.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.Project

  @hold_label "harmony:analysis-only"
  @todo_state "Todo"
  @default_timeout_ms 15_000

  @options_query """
  query HarmonyIntakeLinearOptions {
    teams(first: 100) {
      pageInfo { hasNextPage }
      nodes {
        id
        key
        name
        states(first: 100) { pageInfo { hasNextPage } nodes { id name type } }
        labels(first: 250) { pageInfo { hasNextPage } nodes { id name } }
        projects(first: 100) { pageInfo { hasNextPage } nodes { id name } }
      }
    }
  }
  """

  @label_create_mutation """
  mutation HarmonyIntakeHoldLabelCreate($input: IssueLabelCreateInput!) {
    issueLabelCreate(input: $input) { success issueLabel { id name } }
  }
  """

  @spec fetch_project(term()) :: {:ok, Project.t()} | {:error, :not_found}
  def fetch_project(project_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(project_id),
         %Project{} = project <- Repo.get(Project, uuid) do
      {:ok, project}
    else
      _missing -> {:error, :not_found}
    end
  end

  @spec list(Project.t(), keyword()) :: {:ok, map()} | {:error, {:dependency, String.t()}}
  def list(%Project{} = project, opts \\ []) do
    with {:ok, teams, truncated?} <- fetch_teams(project, opts) do
      {:ok, present(teams, truncated?)}
    end
  end

  @spec ensure_hold_label(Project.t(), String.t(), keyword()) ::
          {:ok, %{label_id: String.t(), created: boolean()}}
          | {:error, {:validation, map()} | {:dependency, String.t()}}
  def ensure_hold_label(%Project{} = project, team_id, opts \\ []) when is_binary(team_id) do
    with {:ok, teams, _truncated?} <- fetch_teams(project, opts) do
      case Enum.find(teams, &(&1["id"] == team_id)) do
        nil -> {:error, {:validation, %{team_id: ["is not a Linear team available to this project"]}}}
        team -> reuse_or_create(project, team, opts)
      end
    end
  end

  defp reuse_or_create(project, team, opts) do
    case hold_label_id(team) do
      label_id when is_binary(label_id) -> {:ok, %{label_id: label_id, created: false}}
      nil -> create_label(project, team["id"], opts)
    end
  end

  defp create_label(project, team_id, opts) do
    variables = %{input: %{name: @hold_label, teamId: team_id}}

    with {:ok, token} <- project_token(project),
         {:ok, body} <- Client.graphql(@label_create_mutation, variables, client_opts(token, opts, "HarmonyIntakeHoldLabelCreate")) do
      case get_in(body, ["data", "issueLabelCreate"]) do
        %{"success" => true, "issueLabel" => %{"id" => id, "name" => @hold_label}} when is_binary(id) ->
          {:ok, %{label_id: id, created: true}}

        _other ->
          {:error, {:dependency, "linear_label_create_failed"}}
      end
    else
      {:error, {:dependency, _code}} = error -> error
      {:error, _reason} -> {:error, {:dependency, "linear_label_create_failed"}}
    end
  end

  defp fetch_teams(project, opts) do
    with {:ok, token} <- project_token(project),
         {:ok, body} <- Client.graphql(@options_query, %{}, client_opts(token, opts, "HarmonyIntakeLinearOptions")),
         %{"nodes" => teams} = connection when is_list(teams) <- get_in(body, ["data", "teams"]) do
      {:ok, teams, truncated?(connection, teams)}
    else
      {:error, {:dependency, _code}} = error -> error
      {:error, reason} -> {:error, {:dependency, error_code(reason)}}
      _unexpected -> {:error, {:dependency, "linear_unavailable"}}
    end
  end

  defp present(teams, truncated?) do
    %{
      teams: Enum.map(teams, &team/1),
      projects: projects(teams),
      states:
        Enum.flat_map(teams, fn team ->
          Enum.map(nodes(team, "states"), &%{id: &1["id"], name: &1["name"], type: &1["type"], team_id: team["id"]})
        end),
      hold_label: %{name: @hold_label},
      truncated: truncated?
    }
  end

  defp team(team) do
    %{
      id: team["id"],
      key: team["key"],
      name: team["name"],
      todo_state_id: team |> nodes("states") |> Enum.find_value(&(&1["name"] == @todo_state && &1["id"])),
      hold_label_id: hold_label_id(team)
    }
  end

  defp hold_label_id(team), do: team |> nodes("labels") |> Enum.find_value(&(&1["name"] == @hold_label && &1["id"]))

  defp projects(teams) do
    teams
    |> Enum.flat_map(fn team -> Enum.map(nodes(team, "projects"), &{&1, team["id"]}) end)
    |> Enum.reduce(%{}, fn {project, team_id}, acc ->
      Map.update(acc, project["id"], %{id: project["id"], name: project["name"], team_ids: [team_id]}, fn existing ->
        %{existing | team_ids: existing.team_ids ++ [team_id]}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  defp nodes(team, key) do
    case get_in(team, [key, "nodes"]) do
      nodes when is_list(nodes) -> Enum.filter(nodes, &is_map/1)
      _missing -> []
    end
  end

  defp truncated?(connection, teams) do
    get_in(connection, ["pageInfo", "hasNextPage"]) == true or
      Enum.any?(teams, fn team ->
        Enum.any?(["states", "labels", "projects"], &(get_in(team, [&1, "pageInfo", "hasNextPage"]) == true))
      end)
  end

  defp project_token(%Project{tracker_secret: token}) when is_binary(token) and token != "" do
    if String.trim(token) != "", do: {:ok, token}, else: global_token()
  end

  defp project_token(%Project{}), do: global_token()

  defp global_token do
    case Config.settings!().tracker.api_key do
      token when is_binary(token) and token != "" -> {:ok, token}
      _missing -> {:error, {:dependency, "missing_linear_api_token"}}
    end
  end

  defp client_opts(token, opts, operation_name) do
    [token: token, retry: false, timeout_ms: @default_timeout_ms, operation_name: operation_name]
    |> Keyword.merge(Keyword.take(opts, [:request_fun, :timeout_ms]))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp error_code({:linear_api_status, status}) when status in [401, 403], do: "linear_auth_failed"
  defp error_code(:missing_linear_api_token), do: "missing_linear_api_token"
  defp error_code(_reason), do: "linear_unavailable"
end
