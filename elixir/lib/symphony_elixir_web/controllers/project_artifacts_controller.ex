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
  alias SymphonyElixirWeb.{Presenter, ProjectRef}

  action_fallback(SymphonyElixirWeb.FallbackController)

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, %{"project_ref" => ref}) do
    with {:ok, project} <- ProjectRef.resolve(ref) do
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
end
