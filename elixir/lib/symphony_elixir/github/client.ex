defmodule SymphonyElixir.Github.Client do
  @moduledoc """
  Minimal GitHub REST client for Harmony PR polling.
  """

  alias SymphonyElixir.Github.{Comment, PullRequest, WorkflowRun}

  @default_api_root "https://api.github.com"

  defp api_root(opts), do: Keyword.get(opts, :base_url) || @default_api_root

  @spec list_open_pull_requests(String.t(), String.t(), keyword()) ::
          {:ok, [PullRequest.t()]} | {:error, term()}
  def list_open_pull_requests(owner, repo, opts \\ [])
      when is_binary(owner) and is_binary(repo) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    token = Keyword.get(opts, :token) || System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")
    url = "#{api_root(opts)}/repos/#{owner}/#{repo}/pulls"

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
    url = "#{api_root(opts)}/repos/#{owner}/#{repo}/issues/#{issue_number}/comments"

    with {:ok, response} <-
           request_fun.(method: :get, url: url, params: [per_page: 100], headers: headers(token)),
         :ok <- expect_status(response, 200) do
      {:ok, Enum.map(response.body, &Comment.from_api/1)}
    end
  end

  @spec create_issue_comment(String.t(), String.t(), pos_integer(), String.t()) :: :ok | {:error, term()}
  def create_issue_comment(owner, repo, issue_number, body) do
    create_issue_comment(owner, repo, issue_number, body, [])
  end

  @spec create_issue_comment(String.t(), String.t(), pos_integer(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_issue_comment(owner, repo, issue_number, body, opts)
      when is_binary(owner) and is_binary(repo) and is_integer(issue_number) and is_binary(body) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    token = github_token(opts)
    url = "#{api_root(opts)}/repos/#{owner}/#{repo}/issues/#{issue_number}/comments"

    case request_fun.(method: :post, url: url, json: %{body: body}, headers: headers(token)) do
      {:ok, response} -> expect_status(response, 201)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_pull_request_review(String.t(), String.t(), pos_integer(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def create_pull_request_review(owner, repo, pr_number, body, opts \\ [])
      when is_binary(owner) and is_binary(repo) and is_integer(pr_number) and is_binary(body) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    token = github_token(opts)
    event = Keyword.get(opts, :event, "COMMENT")
    comments = Keyword.get(opts, :comments, [])
    url = "#{api_root(opts)}/repos/#{owner}/#{repo}/pulls/#{pr_number}/reviews"
    payload = review_payload(body, event, comments)

    case request_fun.(method: :post, url: url, json: payload, headers: headers(token)) do
      {:ok, response} -> expect_status(response, [200, 201])
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_workflow_runs(String.t(), String.t(), keyword()) ::
          {:ok, [WorkflowRun.t()]} | {:error, term()}
  def list_workflow_runs(owner, repo, opts \\ [])
      when is_binary(owner) and is_binary(repo) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    token = github_token(opts)
    url = "#{api_root(opts)}/repos/#{owner}/#{repo}/actions/runs"

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
    url = "#{api_root(opts)}/repos/#{owner}/#{repo}/actions/runs/#{run_id}/logs"

    with {:ok, response} <- request_fun.(method: :get, url: url, headers: headers(token), redirect: true),
         :ok <- expect_status(response, 200) do
      {:ok, response.body}
    end
  end

  @spec list_repos(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_repos(opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    token = github_token(opts)

    url =
      case Keyword.get(opts, :org) do
        nil -> "#{api_root(opts)}/user/repos"
        org -> "#{api_root(opts)}/orgs/#{org}/repos"
      end

    with {:ok, response} <-
           request_fun.(method: :get, url: url, params: [per_page: 100], headers: headers(token)),
         :ok <- expect_status(response, 200) do
      {:ok, response.body}
    end
  end

  @spec get_repo(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_repo(owner, repo, opts \\ [])
      when is_binary(owner) and is_binary(repo) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    token = github_token(opts)
    url = "#{api_root(opts)}/repos/#{owner}/#{repo}"

    with {:ok, response} <-
           request_fun.(method: :get, url: url, headers: headers(token)),
         :ok <- expect_status(response, 200) do
      {:ok, response.body}
    end
  end

  @doc "POST a GraphQL query/mutation. Returns the decoded `\"data\"` map."
  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables, opts \\ []) when is_binary(query) and is_map(variables) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    token = github_token(opts)
    body = Jason.encode!(%{query: query, variables: variables})

    req =
      Req.new(
        method: :post,
        url: graphql_url(opts),
        headers: [{"content-type", "application/json"} | headers(token)],
        body: body
      )

    case request_fun.(req) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_map(data) -> {:ok, data}
      {:ok, %{status: status, body: body}} -> {:error, {:github_graphql_status, status, body}}
      {:error, reason} -> {:error, {:github_graphql_request, reason}}
    end
  end

  # github.com → https://api.github.com/graphql; Enterprise base_url host → {host}/api/graphql.
  defp graphql_url(opts) do
    case Keyword.get(opts, :base_url) do
      nil -> "https://api.github.com/graphql"
      base -> base |> String.replace_suffix("/api/v3", "") |> Kernel.<>("/api/graphql")
    end
  end

  defp github_token(opts), do: Keyword.get(opts, :token) || System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")

  defp review_payload(body, event, comments) when is_list(comments) and comments != [] do
    %{body: body, event: event, comments: comments}
  end

  defp review_payload(body, event, _comments), do: %{body: body, event: event}

  defp headers(token) when is_binary(token) and token != "" do
    [{"authorization", "Bearer #{token}"}, {"accept", "application/vnd.github+json"}]
  end

  defp headers(_token), do: [{"accept", "application/vnd.github+json"}]

  defp expect_status(%{status: status, body: body}, expected) when is_list(expected) do
    if status in expected, do: :ok, else: {:error, {:github_status, status, body}}
  end

  defp expect_status(%{status: status}, expected) when status == expected, do: :ok
  defp expect_status(%{status: status, body: body}, _expected), do: {:error, {:github_status, status, body}}
end
