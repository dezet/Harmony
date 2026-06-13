defmodule SymphonyElixirWeb.ProjectActivityController do
  @moduledoc """
  JSON endpoint for the paginated project-wide activity feed (work events).

  Route parameter:
  - `project_ref` — project UUID or slug

  Query parameters:
  - `cursor`     (optional) — opaque pagination cursor (base64url JSON)
  - `page_size`  (optional) — integer; default 50, cap 200, floor 1; non-numeric → default

  Response: `%{items: [RunStreamItem...], meta: %{next_cursor: string | null}}`.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Storage
  alias SymphonyElixirWeb.Presenter

  action_fallback(SymphonyElixirWeb.FallbackController)

  @default_page_size 50
  @max_page_size 200
  @min_page_size 1

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, %{"project_ref" => ref} = params) do
    with {:ok, project} <- fetch_project(ref) do
      page_size = parse_page_size(params["page_size"])

      opts =
        case params["cursor"] do
          nil -> %{page_size: page_size}
          "" -> %{page_size: page_size}
          cursor -> %{page_size: page_size, cursor: cursor}
        end

      events = Storage.list_work_events_for_project(project.id, opts)
      json(conn, Presenter.project_activity_payload(events, page_size))
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

  defp parse_page_size(nil), do: @default_page_size
  defp parse_page_size(""), do: @default_page_size

  defp parse_page_size(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} ->
        n
        |> max(@min_page_size)
        |> min(@max_page_size)

      _ ->
        @default_page_size
    end
  end
end
