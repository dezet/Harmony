defmodule SymphonyElixirWeb.TrackerPickerController do
  @moduledoc """
  Stateless tracker-project picker: lists Linear projects using a token from the
  request body (global-env fallback). The token is never persisted or echoed.
  """
  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Tracker

  @cap 200

  @spec projects(Conn.t(), map()) :: Conn.t()
  def projects(conn, params) do
    token = blank_to_nil(params["token"]) || System.get_env("LINEAR_API_KEY")

    cond do
      is_nil(token) ->
        error(conn, 422, "missing_credentials")

      true ->
        case Tracker.list_projects(%{token: token}) do
          {:ok, projects} ->
            capped = Enum.take(projects, @cap)

            json(conn, %{
              projects: Enum.map(capped, &project_json/1),
              truncated: length(projects) > @cap
            })

          {:error, reason} ->
            map_error(conn, reason)
        end
    end
  end

  defp project_json(p) do
    %{id: p[:id], name: p[:name], slug: p[:slug], team_key: p[:team_key]}
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)

  defp map_error(conn, reason) do
    if auth_status?(reason) do
      error(conn, 422, "tracker_auth_failed")
    else
      error(conn, 502, "tracker_unreachable")
    end
  end

  defp auth_status?(reason) when is_tuple(reason) do
    reason |> Tuple.to_list() |> Enum.any?(&(&1 in [401, 403]))
  end

  defp auth_status?(_reason), do: false

  defp error(conn, status, code) do
    conn |> put_status(status) |> json(%{error: %{code: code}})
  end
end
