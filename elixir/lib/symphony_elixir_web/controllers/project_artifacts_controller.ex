defmodule SymphonyElixirWeb.ProjectArtifactsController do
  @moduledoc """
  JSON endpoint listing all artifacts for a given project.

  Route parameter:
  - `project_ref` — project UUID or slug

  Response: `%{artifacts: [%{id, kind, metadata, work_run_id, work_run}]}`.
  The `path` field is intentionally omitted; artifact content is served by
  `ArtifactController`.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Storage
  alias SymphonyElixirWeb.Presenter

  action_fallback(SymphonyElixirWeb.FallbackController)

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, %{"project_ref" => ref}) do
    with {:ok, project} <- fetch_project(ref) do
      artifacts = Storage.list_artifacts_for_project(project.id)
      json(conn, Presenter.project_artifacts_payload(artifacts))
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> put_status(405)
    |> json(%{error: %{code: "method_not_allowed", message: "Method not allowed"}})
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_project(ref) do
    case Ecto.UUID.cast(ref) do
      {:ok, _uuid} ->
        try do
          {:ok, Storage.get_project!(ref)}
        rescue
          Ecto.NoResultsError ->
            case Storage.get_project_by_slug(ref) do
              nil -> {:error, :not_found}
              project -> {:ok, project}
            end
        end

      :error ->
        case Storage.get_project_by_slug(ref) do
          nil -> {:error, :not_found}
          project -> {:ok, project}
        end
    end
  end
end
