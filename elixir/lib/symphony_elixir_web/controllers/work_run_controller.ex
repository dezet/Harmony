defmodule SymphonyElixirWeb.WorkRunController do
  @moduledoc """
  JSON endpoint for paginated work-run history for a given project.

  Query parameters:
  - `project` (required) — project slug
  - `status`   (optional) — filter by work-run status string
  - `cursor`   (optional) — opaque pagination cursor (base64url JSON)
  - `page_size` (optional) — integer; default 25, cap 100, floor 1; non-numeric → default
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Storage
  alias SymphonyElixirWeb.Presenter

  action_fallback(SymphonyElixirWeb.FallbackController)

  @default_page_size 25
  @max_page_size 100
  @min_page_size 1

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, params) do
    with {:ok, project} <- resolve_project(params) do
      opts = build_opts(params)
      runs = Storage.list_work_runs_for_project(project.id, opts)
      json(conn, Presenter.work_run_list_payload(runs, opts.page_size))
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

  defp resolve_project(%{"project" => slug}) when is_binary(slug) and slug != "" do
    case Storage.get_project_by_slug(slug) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  defp resolve_project(_params), do: {:error, :not_found}

  defp build_opts(params) do
    page_size = parse_page_size(params["page_size"])

    opts = %{page_size: page_size}

    opts =
      case params["status"] do
        nil -> opts
        "" -> opts
        status -> Map.put(opts, :status, status)
      end

    opts =
      case params["cursor"] do
        nil -> opts
        "" -> opts
        cursor -> Map.put(opts, :cursor, cursor)
      end

    opts
  end

  defp parse_page_size(nil), do: @default_page_size
  defp parse_page_size(""), do: @default_page_size

  defp parse_page_size(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _rest} ->
        n
        |> max(@min_page_size)
        |> min(@max_page_size)

      :error ->
        @default_page_size
    end
  end
end
