defmodule SymphonyElixirWeb.ForgePickerController do
  @moduledoc """
  Stateless repository picker: lists a forge's repositories using a token from
  the request body (global-env fallback), for the Configuration form pickers.
  The token is never persisted or echoed.
  """
  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Forge

  @cap 200

  @spec repositories(Conn.t(), map()) :: Conn.t()
  def repositories(conn, params) do
    forge_type = params["forge_type"] || "github"
    token = blank_to_nil(params["token"]) || env_token(forge_type)
    base_url = blank_to_nil(params["base_url"])

    cond do
      is_nil(token) ->
        error(conn, 422, "missing_credentials")

      true ->
        creds = %{token: token, base_url: base_url, request_fun: nil}

        case Forge.adapter(%{forge_type: forge_type}).list_repositories(creds, []) do
          {:ok, repos} ->
            capped = Enum.take(repos, @cap)

            json(conn, %{
              repositories: Enum.map(capped, &repo_json/1),
              truncated: length(repos) > @cap
            })

          {:error, reason} ->
            map_error(conn, reason, "forge")
        end
    end
  end

  defp repo_json(r) do
    %{owner: r[:owner], name: r[:name], default_branch: r[:default_branch], url: r[:url]}
  end

  defp env_token("gitlab"), do: System.get_env("GITLAB_TOKEN")
  defp env_token(_), do: System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)

  defp map_error(conn, reason, prefix) do
    if auth_status?(reason) do
      error(conn, 422, "#{prefix}_auth_failed")
    else
      error(conn, 502, "#{prefix}_unreachable")
    end
  end

  # Adapter errors carry the upstream status in a tuple, e.g. {:github_api_status, 401}.
  defp auth_status?(reason) when is_tuple(reason) do
    reason |> Tuple.to_list() |> Enum.any?(&(&1 in [401, 403]))
  end

  defp auth_status?(_reason), do: false

  defp error(conn, status, code) do
    conn |> put_status(status) |> json(%{error: %{code: code}})
  end
end
