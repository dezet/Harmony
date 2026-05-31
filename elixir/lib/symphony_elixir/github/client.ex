defmodule SymphonyElixir.Github.Client do
  @moduledoc """
  Minimal GitHub REST client for Harmony PR polling.
  """

  alias SymphonyElixir.Github.{Comment, PullRequest, WorkflowRun}

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

  @spec list_issue_comments(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, [Comment.t()]} | {:error, term()}
  def list_issue_comments(owner, repo, issue_number, opts \\ [])
      when is_binary(owner) and is_binary(repo) and is_integer(issue_number) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    token = github_token(opts)
    url = "#{@api_root}/repos/#{owner}/#{repo}/issues/#{issue_number}/comments"

    with {:ok, response} <-
           request_fun.(method: :get, url: url, params: [per_page: 100], headers: headers(token)),
         :ok <- expect_status(response, 200) do
      {:ok, Enum.map(response.body, &Comment.from_api/1)}
    end
  end

  @spec list_workflow_runs(String.t(), String.t(), keyword()) ::
          {:ok, [WorkflowRun.t()]} | {:error, term()}
  def list_workflow_runs(owner, repo, opts \\ [])
      when is_binary(owner) and is_binary(repo) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    token = github_token(opts)
    url = "#{@api_root}/repos/#{owner}/#{repo}/actions/runs"

    params =
      [per_page: 100]
      |> Keyword.merge(if Keyword.get(opts, :head_sha), do: [head_sha: Keyword.fetch!(opts, :head_sha)], else: [])

    with {:ok, response} <-
           request_fun.(method: :get, url: url, params: params, headers: headers(token)),
         :ok <- expect_status(response, 200) do
      {:ok, response.body["workflow_runs"] |> List.wrap() |> Enum.map(&WorkflowRun.from_api/1)}
    end
  end

  @spec get_workflow_run_logs(String.t(), String.t(), pos_integer(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_workflow_run_logs(owner, repo, run_id, opts \\ [])
      when is_binary(owner) and is_binary(repo) and is_integer(run_id) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    token = github_token(opts)
    url = "#{@api_root}/repos/#{owner}/#{repo}/actions/runs/#{run_id}/logs"

    with {:ok, response} <- request_fun.(method: :get, url: url, headers: headers(token), redirect: true),
         :ok <- expect_status(response, 200) do
      {:ok, response.body}
    end
  end

  defp github_token(opts), do: Keyword.get(opts, :token) || System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")

  defp headers(token) when is_binary(token) and token != "" do
    [{"authorization", "Bearer #{token}"}, {"accept", "application/vnd.github+json"}]
  end

  defp headers(_token), do: [{"accept", "application/vnd.github+json"}]

  defp expect_status(%{status: status}, expected) when status == expected, do: :ok
  defp expect_status(%{status: status, body: body}, _expected), do: {:error, {:github_status, status, body}}
end
