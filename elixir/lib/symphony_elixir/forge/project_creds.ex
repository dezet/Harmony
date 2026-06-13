defmodule SymphonyElixir.Forge.ProjectCreds do
  @moduledoc """
  Shared helpers that build `creds`, `repo_ref`, and `client_opts` from a
  project or work-run map/struct for use with the `Forge` adapter behaviour
  and the underlying `Github.Client`.

  Falls back to `github_owner` / `github_repo` when the `forge_*` fields are
  absent (safe during the transition period while older records pre-date the
  forge migration).
  """

  # ---------------------------------------------------------------------------
  # repo_ref/1 — build a %{owner:, repo:, base_url:} from a project or WorkRun
  # ---------------------------------------------------------------------------

  @doc """
  Returns a `Forge.repo_ref()` map for *project* (or any map that carries
  forge / github owner+repo fields).

      %{owner: "acme", repo: "api", base_url: nil}
  """
  @spec repo_ref(map()) :: %{owner: String.t() | nil, repo: String.t() | nil, base_url: String.t() | nil}
  def repo_ref(project_or_run) do
    owner =
      map_get(project_or_run, :forge_owner) ||
        map_get(project_or_run, :github_owner)

    repo =
      map_get(project_or_run, :forge_repo) ||
        map_get(project_or_run, :github_repo)

    base_url = map_get(project_or_run, :forge_base_url)

    %{owner: owner, repo: repo, base_url: base_url}
  end

  # ---------------------------------------------------------------------------
  # creds/2 — build a creds map for the Forge adapter behaviour
  # ---------------------------------------------------------------------------

  @doc """
  Returns a `Forge.creds()` map for *project*.

  Pass any extra options (e.g. `[request_fun: fun]`) as *extra* — they are
  merged in so that test-injected HTTP functions flow transparently through
  to `Github.Client`.
  """
  @spec creds(map(), keyword()) :: map()
  def creds(project_or_run, extra \\ []) do
    token = System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")
    base_url = map_get(project_or_run, :forge_base_url)

    %{
      token: token,
      base_url: base_url,
      request_fun: extra[:request_fun]
    }
  end

  # ---------------------------------------------------------------------------
  # client_opts/2 — build keyword opts for Github.Client calls
  # ---------------------------------------------------------------------------

  @doc """
  Returns a keyword list suitable for passing directly to `Github.Client`
  functions (e.g. `list_open_pull_requests/3`).

  Reads `forge_base_url` from the project/work-run and the GitHub token from
  the environment. Includes `request_fun` when provided in *extra* so that
  test injection continues to work transparently.
  """
  @spec client_opts(map(), keyword()) :: keyword()
  def client_opts(project_or_run, extra \\ []) do
    token = System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")
    base_url = map_get(project_or_run, :forge_base_url)

    []
    |> put_if(token, :token)
    |> put_if(base_url, :base_url)
    |> put_if(extra[:request_fun], :request_fun)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp put_if(opts, nil, _key), do: opts
  defp put_if(opts, value, key), do: Keyword.put(opts, key, value)
end
