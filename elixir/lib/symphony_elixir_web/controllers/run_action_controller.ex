defmodule SymphonyElixirWeb.RunActionController do
  @moduledoc """
  JSON endpoints for operator-initiated run actions (stop, retry-now).

  Routes:
    POST /api/v1/runs/:identifier/stop  — soft-stop the current attempt
    POST /api/v1/runs/:identifier/retry — fire retry-now on a retrying run
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.Endpoint

  action_fallback(SymphonyElixirWeb.FallbackController)

  # ---------------------------------------------------------------------------
  # stop — POST /api/v1/runs/:identifier/stop
  # ---------------------------------------------------------------------------

  @spec stop(Conn.t(), map()) :: Conn.t()
  def stop(conn, %{"identifier" => identifier}) do
    orchestrator = Endpoint.config(:orchestrator) || Orchestrator

    case get_snapshot(orchestrator) do
      {:ok, snapshot} ->
        case find_issue_id(identifier, snapshot) do
          nil ->
            {:error, :run_not_found}

          issue_id ->
            case Orchestrator.stop_run(orchestrator, issue_id) do
              :ok -> json(conn, %{status: "stopped"})
              {:error, reason} -> {:error, reason}
            end
        end

      {:snapshot_error, status_code, error_body} ->
        conn
        |> put_status(status_code)
        |> json(error_body)
    end
  end

  # ---------------------------------------------------------------------------
  # retry — POST /api/v1/runs/:identifier/retry
  # ---------------------------------------------------------------------------

  @spec retry(Conn.t(), map()) :: Conn.t()
  def retry(conn, %{"identifier" => identifier}) do
    orchestrator = Endpoint.config(:orchestrator) || Orchestrator

    case get_snapshot(orchestrator) do
      {:ok, snapshot} ->
        case find_issue_id(identifier, snapshot) do
          nil ->
            {:error, :run_not_found}

          issue_id ->
            case Orchestrator.retry_now(orchestrator, issue_id) do
              :ok -> json(conn, %{status: "retrying"})
              {:error, reason} -> {:error, reason}
            end
        end

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

  defp get_snapshot(orchestrator) do
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

  # Scans running, retrying (retry_attempts), and blocked maps to find the
  # issue_id for a given identifier. Returns nil if not found in any of the
  # three live maps.
  defp find_issue_id(identifier, snapshot) do
    running = Enum.find(snapshot.running, &(&1.identifier == identifier))
    retry = Enum.find(snapshot.retrying, &(&1.identifier == identifier))
    blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == identifier))

    entry = running || retry || blocked

    if entry do
      entry.issue_id
    else
      nil
    end
  end
end
