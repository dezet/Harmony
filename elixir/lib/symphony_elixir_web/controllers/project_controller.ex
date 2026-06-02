defmodule SymphonyElixirWeb.ProjectController do
  @moduledoc """
  JSON CRUD for projects (list / show / create / update). Mirrors the LiveView
  project form. No delete by design.
  """

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.Storage

  action_fallback(SymphonyElixirWeb.FallbackController)

  @permitted ~w(slug linear_project_slug linear_team_key linear_human_review_state
                github_owner github_repo github_base_branch config_version config)

  def index(conn, _params) do
    json(conn, %{projects: Enum.map(Storage.list_projects(), &project_json/1)})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, project} <- fetch_project(id) do
      json(conn, %{project: project_json(project)})
    end
  end

  def create(conn, params) do
    with {:ok, project} <- Storage.upsert_project(project_attrs(params)) do
      conn |> put_status(:created) |> json(%{project: project_json(project)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, _existing} <- fetch_project(id),
         {:ok, project} <- Storage.upsert_project(project_attrs(params)) do
      json(conn, %{project: project_json(project)})
    end
  end

  defp fetch_project(id) do
    {:ok, Storage.get_project!(id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp project_attrs(params), do: Map.take(params, @permitted)

  defp project_json(p) do
    %{
      id: p.id,
      slug: p.slug,
      linear_project_slug: p.linear_project_slug,
      linear_team_key: p.linear_team_key,
      linear_human_review_state: p.linear_human_review_state,
      github_owner: p.github_owner,
      github_repo: p.github_repo,
      github_base_branch: p.github_base_branch,
      config_version: p.config_version,
      config: p.config,
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end
end
