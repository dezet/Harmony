defmodule SymphonyElixirWeb.GitlabWebhookController do
  @moduledoc """
  GitLab webhook receiver: review/MR events nudge a project refresh.

  Mirrors `SymphonyElixirWeb.GithubWebhookController` — it verifies the
  `X-Gitlab-Token` header against a configured secret, and for review-relevant
  events (`Note Hook`, `Merge Request Hook`) appends the webhook event to
  storage and requests an orchestrator refresh. There is no direct dispatch:
  the polling source remains the single source of truth.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Storage
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @supported_events MapSet.new(["Note Hook", "Merge Request Hook"])

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, params) do
    with :ok <- verify_token(conn),
         {:ok, event} <- gitlab_event(conn) do
      handle_verified_event(conn, event, params)
    else
      {:error, conn} -> conn
    end
  end

  defp handle_verified_event(conn, event, params) do
    if MapSet.member?(@supported_events, event) do
      _ = nudge_refresh(params, event, conn)
      refresh = request_refresh()

      conn
      |> put_status(200)
      |> json(%{status: "accepted", event: event, refresh: refresh})
    else
      conn
      |> put_status(200)
      |> json(%{status: "ignored", event: event})
    end
  end

  defp verify_token(conn) do
    secret = Application.get_env(:symphony_elixir, :gitlab_webhook_secret)
    header = conn |> Conn.get_req_header("x-gitlab-token") |> List.first()

    cond do
      not (is_binary(secret) and secret != "") ->
        {:error, invalid_token(conn)}

      secure_compare(header, secret) ->
        :ok

      true ->
        {:error, invalid_token(conn)}
    end
  end

  defp invalid_token(conn) do
    error_response(conn, 401, "invalid_token", "GitLab webhook token is invalid")
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

  defp gitlab_event(conn) do
    case conn |> Conn.get_req_header("x-gitlab-event") |> List.first() do
      event when is_binary(event) and event != "" ->
        {:ok, event}

      _missing ->
        {:error, error_response(conn, 400, "missing_event", "GitLab event header is missing")}
    end
  end

  # Mirror the GitHub controller: append the webhook event to storage when the
  # project resolves. The refresh itself is requested unconditionally in
  # `handle_verified_event/3`, matching GitHub's "nudge the poller" model.
  defp nudge_refresh(params, event, _conn) do
    case resolve_project(params) do
      {:ok, project} -> append_webhook_event(project, event, params)
      {:error, :project_not_found} -> :ok
    end
  end

  defp resolve_project(params) do
    with project_info when is_map(project_info) <- Map.get(params, "project"),
         path when is_binary(path) <- Map.get(project_info, "path_with_namespace"),
         {owner, repo} when is_binary(owner) and is_binary(repo) <- split_path(path),
         project when not is_nil(project) <- Storage.get_project_by_gitlab(owner, repo) do
      {:ok, project}
    else
      _missing -> {:error, :project_not_found}
    end
  end

  defp split_path(path) do
    case String.split(path, "/") do
      [_ | _] = parts when length(parts) >= 2 ->
        {repo, owner_parts} = List.pop_at(parts, -1)
        {Enum.join(owner_parts, "/"), repo}

      _other ->
        :error
    end
  end

  defp append_webhook_event(project, event, params) do
    Storage.append_event(%{
      project_id: project.id,
      type: "gitlab_webhook:#{event}",
      payload: %{
        "event" => event,
        "object_kind" => Map.get(params, "object_kind"),
        "project" => Map.get(params, "project"),
        "payload" => params
      }
    })
  end

  defp request_refresh do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} -> payload
      {:error, :unavailable} -> %{queued: false, error: "orchestrator_unavailable"}
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
