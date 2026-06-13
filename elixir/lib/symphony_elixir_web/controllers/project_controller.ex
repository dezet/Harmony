defmodule SymphonyElixirWeb.ProjectController do
  @moduledoc """
  JSON CRUD for projects (list / show / create / update) consumed by the React
  SPA's project form. No delete by design.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Storage

  action_fallback(SymphonyElixirWeb.FallbackController)

  @permitted ~w(slug linear_project_slug linear_team_key linear_human_review_state
                github_owner github_repo github_base_branch forge_type forge_owner
                forge_repo forge_base_branch forge_base_url config_version config)

  @secret_params ~w(forge_secret tracker_secret clear_forge_secret clear_tracker_secret)

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, _params) do
    json(conn, %{projects: Enum.map(Storage.list_projects(), &project_json/1)})
  end

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, project} <- fetch_project(id) do
      json(conn, %{project: project_json(project)})
    end
  end

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, params) do
    with {:ok, project} <- Storage.upsert_project(project_attrs(params)),
         {:ok, project} <- apply_secrets(project, params) do
      conn |> put_status(:created) |> json(%{project: project_json(project)})
    end
  end

  @spec update(Conn.t(), map()) :: Conn.t()
  def update(conn, %{"id" => id} = params) do
    with {:ok, _existing} <- fetch_project(id),
         {:ok, project} <- Storage.upsert_project(project_attrs(params)),
         {:ok, project} <- apply_secrets(project, params) do
      json(conn, %{project: project_json(project)})
    end
  end

  defp apply_secrets(project, params) do
    if Enum.any?(@secret_params, &Map.has_key?(params, &1)) do
      Storage.update_project_secrets(project, Map.take(params, @secret_params))
    else
      {:ok, project}
    end
  end

  defp fetch_project(id) do
    {:ok, Storage.get_project!(id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  # Accept legacy github_* HTTP params and remap them to forge_* for storage.
  # Explicit forge_* params (if present) take precedence over the github_* aliases.
  defp project_attrs(params) do
    params
    |> Map.take(@permitted)
    |> then(fn p ->
      p
      |> maybe_remap("github_owner", "forge_owner")
      |> maybe_remap("github_repo", "forge_repo")
      |> maybe_remap("github_base_branch", "forge_base_branch")
      |> Map.drop(["github_owner", "github_repo", "github_base_branch"])
    end)
  end

  defp maybe_remap(params, from_key, to_key) do
    case {Map.get(params, from_key), Map.has_key?(params, to_key)} do
      {val, false} when not is_nil(val) -> Map.put(params, to_key, val)
      _ -> params
    end
  end

  defp project_json(p) do
    %{
      id: p.id,
      slug: p.slug,
      linear_project_slug: p.linear_project_slug,
      linear_team_key: p.linear_team_key,
      linear_human_review_state: p.linear_human_review_state,
      github_owner: p.forge_owner,
      github_repo: p.forge_repo,
      github_base_branch: p.forge_base_branch,
      forge_secret: secret_state(p.forge_secret),
      tracker_secret: secret_state(p.tracker_secret),
      config_version: p.config_version,
      config: p.config,
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  defp secret_state(nil), do: "unset"
  defp secret_state(_), do: "set"
end
