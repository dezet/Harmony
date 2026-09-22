defmodule SymphonyElixirWeb.RunDetailController do
  @moduledoc """
  JSON endpoints for per-run detail and paginated work-event stream.

  Routes:
    GET /api/v1/runs/:identifier        — merged live+durable run detail
    GET /api/v1/runs/:identifier/stream — paginated ascending work-events
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Orchestrator, Storage}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  action_fallback(SymphonyElixirWeb.FallbackController)

  @default_page_size 50
  @max_page_size 200
  @min_page_size 1

  # ---------------------------------------------------------------------------
  # show — GET /api/v1/runs/:identifier
  # ---------------------------------------------------------------------------

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"identifier" => identifier}) do
    work_run = Storage.get_work_run_by_linear_identifier(identifier)

    case get_snapshot(conn) do
      {:ok, snapshot} ->
        show_snapshot(conn, identifier, work_run, snapshot)

      {:snapshot_error, status_code, error_body} ->
        conn
        |> put_status(status_code)
        |> json(error_body)
    end
  end

  # ---------------------------------------------------------------------------
  # stream — GET /api/v1/runs/:identifier/stream
  # ---------------------------------------------------------------------------

  @spec stream(Conn.t(), map()) :: Conn.t()
  def stream(conn, %{"identifier" => identifier} = params) do
    work_run = Storage.get_work_run_by_linear_identifier(identifier)

    case get_snapshot(conn) do
      {:ok, snapshot} ->
        stream_snapshot(conn, identifier, params, work_run, snapshot)

      {:snapshot_error, status_code, error_body} ->
        conn
        |> put_status(status_code)
        |> json(error_body)
    end
  end

  # ---------------------------------------------------------------------------
  # method_not_allowed
  # ---------------------------------------------------------------------------

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> put_status(405)
    |> json(%{error: %{code: "method_not_allowed", message: "Method not allowed"}})
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp show_snapshot(conn, identifier, work_run, snapshot) do
    live = find_live_entry(identifier, snapshot)

    if is_nil(work_run) and is_nil(live) do
      {:error, :run_not_found}
    else
      has_live = not is_nil(live)
      pr_links = run_pull_request_links(work_run, identifier)
      artifacts = run_artifacts(work_run)
      project = run_project(work_run)
      stream_cursor = run_stream_cursor(work_run, has_live)

      payload =
        Presenter.run_detail_payload(identifier, work_run, snapshot, pr_links, artifacts, project)
        |> Map.put(:stream_cursor, stream_cursor)

      json(conn, payload)
    end
  end

  defp run_pull_request_links(%{project_id: project_id}, identifier) when not is_nil(project_id) do
    project_id
    |> Storage.list_pull_request_links_for_project()
    |> Enum.filter(&(&1.linear_identifier == identifier))
  end

  defp run_pull_request_links(_work_run, _identifier), do: []

  defp run_artifacts(%{id: id}), do: Storage.list_artifacts_for_work_run(id)
  defp run_artifacts(_work_run), do: []

  defp run_project(%{project_id: project_id}) when not is_nil(project_id) do
    Storage.get_project!(project_id)
  rescue
    Ecto.NoResultsError -> nil
  end

  defp run_project(_work_run), do: nil

  defp run_stream_cursor(%{id: id}, has_live) do
    page = Storage.list_work_events_for_run(id, %{page_size: @default_page_size})
    Presenter.run_stream_payload(page, @default_page_size, has_live).meta.next_cursor
  end

  defp run_stream_cursor(_work_run, _has_live), do: nil

  defp stream_snapshot(conn, identifier, params, work_run, snapshot) do
    live = find_live_entry(identifier, snapshot)

    cond do
      is_nil(work_run) and is_nil(live) ->
        {:error, :run_not_found}

      is_nil(work_run) ->
        json(conn, %{items: [], meta: %{next_cursor: nil, has_live: true}})

      true ->
        page_size = parse_page_size(params["page_size"])
        opts = build_stream_opts(params, page_size)
        events = Storage.list_work_events_for_run(work_run.id, opts)
        json(conn, Presenter.run_stream_payload(events, page_size, not is_nil(live)))
    end
  end

  defp get_snapshot(_conn) do
    orchestrator = Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
    timeout_ms = Endpoint.config(:snapshot_timeout_ms) || 15_000

    case Orchestrator.snapshot(orchestrator, timeout_ms) do
      %{} = snapshot ->
        {:ok, snapshot}

      :timeout ->
        {:snapshot_error, 503, %{error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}}

      :unavailable ->
        {:snapshot_error, 503, %{error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}}
    end
  end

  defp find_live_entry(identifier, snapshot) do
    running = Enum.find(snapshot.running, &(&1.identifier == identifier))
    retry = Enum.find(snapshot.retrying, &(&1.identifier == identifier))
    blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == identifier))
    running || retry || blocked
  end

  defp build_stream_opts(params, page_size) do
    opts = %{page_size: page_size}

    case params["cursor"] do
      nil -> opts
      "" -> opts
      cursor -> Map.put(opts, :cursor, cursor)
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
