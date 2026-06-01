defmodule SymphonyElixirWeb.GithubWebhookController do
  @moduledoc """
  GitHub webhook receiver for project refresh events.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Storage
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @supported_events MapSet.new(["pull_request", "issue_comment", "workflow_run"])

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, params) do
    with {:ok, secret} <- webhook_secret(),
         :ok <- verify_signature(conn, secret),
         {:ok, event} <- github_event(conn) do
      handle_verified_event(conn, event, params)
    else
      {:error, :missing_secret} ->
        error_response(conn, 503, "webhook_secret_missing", "GitHub webhook secret is not configured")

      {:error, :invalid_signature} ->
        error_response(conn, 401, "invalid_signature", "GitHub webhook signature is invalid")

      {:error, :missing_event} ->
        error_response(conn, 400, "missing_event", "GitHub event header is missing")
    end
  end

  defp handle_verified_event(conn, event, params) do
    if MapSet.member?(@supported_events, event) do
      with {:ok, project} <- resolve_project(params),
           {:ok, _event} <- append_webhook_event(project, event, conn, params) do
        refresh = request_refresh()

        conn
        |> put_status(202)
        |> json(%{status: "accepted", event: event, refresh: refresh})
      else
        {:error, :project_not_found} ->
          error_response(conn, 404, "project_not_found", "No configured project matches the webhook repository")

        {:error, reason} ->
          error_response(conn, 500, "webhook_store_failed", inspect(reason))
      end
    else
      conn
      |> put_status(202)
      |> json(%{status: "ignored", event: event})
    end
  end

  defp webhook_secret do
    case Application.get_env(:symphony_elixir, :github_webhook_secret) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _missing -> {:error, :missing_secret}
    end
  end

  defp verify_signature(conn, secret) do
    expected = "sha256=" <> hmac_sha256(secret, raw_body(conn))
    signature = conn |> get_req_header("x-hub-signature-256") |> List.first()

    if secure_compare(signature, expected) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp hmac_sha256(secret, body) do
    :crypto.mac(:hmac, :sha256, secret, body)
    |> Base.encode16(case: :lower)
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

  defp raw_body(conn) do
    conn.assigns
    |> Map.get(:raw_body, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp github_event(conn) do
    case conn |> get_req_header("x-github-event") |> List.first() do
      event when is_binary(event) and event != "" -> {:ok, event}
      _missing -> {:error, :missing_event}
    end
  end

  defp resolve_project(params) do
    with repo when is_map(repo) <- Map.get(params, "repository"),
         owner when is_binary(owner) <- repository_owner(repo),
         name when is_binary(name) <- Map.get(repo, "name"),
         project when not is_nil(project) <- Storage.get_project_by_github(owner, name) do
      {:ok, project}
    else
      _missing -> {:error, :project_not_found}
    end
  end

  defp repository_owner(repo) do
    get_in(repo, ["owner", "login"]) || get_in(repo, ["owner", "name"])
  end

  defp append_webhook_event(project, event, conn, params) do
    Storage.append_event(%{
      project_id: project.id,
      type: "github_webhook:#{event}",
      payload: %{
        "event" => event,
        "delivery" => conn |> get_req_header("x-github-delivery") |> List.first(),
        "action" => Map.get(params, "action"),
        "repository" => Map.get(params, "repository"),
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
