defmodule SymphonyElixirWeb.ProjectSummaryController do
  @moduledoc """
  JSON endpoint for the per-project summary: live running/retrying/blocked entries
  from the orchestrator snapshot plus durable human-review PR links.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Orchestrator, Storage}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  action_fallback(SymphonyElixirWeb.FallbackController)

  @spec summary(Conn.t(), map()) :: Conn.t()
  def summary(conn, %{"project_ref" => ref}) do
    with {:ok, project} <- fetch_project(ref) do
      snapshot = Orchestrator.snapshot(orchestrator(), snapshot_timeout_ms())
      links = Storage.list_pull_request_links_for_project(project.id)

      case snapshot do
        %{} = snap ->
          json(conn, Presenter.project_summary_payload(project, snap, links))

        :timeout ->
          conn
          |> put_status(503)
          |> json(%{error: %{code: "snapshot_timeout", message: "Snapshot timed out"}})

        :unavailable ->
          conn
          |> put_status(503)
          |> json(%{error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}})
      end
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
        {:ok, Storage.get_project!(ref)}

      :error ->
        case Storage.get_project_by_slug(ref) do
          nil -> {:error, :not_found}
          project -> {:ok, project}
        end
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
