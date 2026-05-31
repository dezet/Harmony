defmodule SymphonyElixir.Github.Client do
  @moduledoc """
  Minimal GitHub REST client for Harmony PR polling.
  """

  alias SymphonyElixir.Github.PullRequest

  @api_root "https://api.github.com"

  @spec list_open_pull_requests(String.t(), String.t(), keyword()) ::
          {:ok, [PullRequest.t()]} | {:error, term()}
  def list_open_pull_requests(owner, repo, opts \\ [])
      when is_binary(owner) and is_binary(repo) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    token = Keyword.get(opts, :token) || System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")
    url = "#{@api_root}/repos/#{owner}/#{repo}/pulls"

    with {:ok, response} <-
           request_fun.(
             method: :get,
             url: url,
             params: [state: "open", per_page: 100],
             headers: headers(token)
           ),
         :ok <- expect_status(response, 200) do
      {:ok, Enum.map(response.body, &PullRequest.from_api/1)}
    end
  end

  defp headers(token) when is_binary(token) and token != "" do
    [{"authorization", "Bearer #{token}"}, {"accept", "application/vnd.github+json"}]
  end

  defp headers(_token), do: [{"accept", "application/vnd.github+json"}]

  defp expect_status(%{status: status}, expected) when status == expected, do: :ok
  defp expect_status(%{status: status, body: body}, _expected), do: {:error, {:github_status, status, body}}
end
