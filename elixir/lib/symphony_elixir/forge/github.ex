defmodule SymphonyElixir.Forge.Github do
  @moduledoc """
  Forge adapter for GitHub (github.com and GitHub Enterprise).

  Accepts creds as a map with optional keys:
    - `:token` — GitHub API token
    - `:base_url` — override API root (e.g. "https://ghe.example.com" for GHE)
    - `:request_fun` — HTTP request injection (used in tests)
    - `:org` — org name for `list_repositories` to use /orgs/:org/repos
  """

  @behaviour SymphonyElixir.Forge

  alias SymphonyElixir.Github.Client

  # --- Behaviour callbacks ---

  @impl true
  def list_repositories(creds, opts) do
    with {:ok, repos} <- Client.list_repos(client_opts(creds) ++ opts) do
      {:ok, Enum.map(repos, &normalize_repo/1)}
    end
  end

  @impl true
  def get_repository(creds, owner, repo) do
    with {:ok, body} <- Client.get_repo(owner, repo, client_opts(creds)) do
      {:ok, normalize_repo(body)}
    end
  end

  @impl true
  def list_change_requests(creds, ref, _opts) do
    with {:ok, prs} <- Client.list_open_pull_requests(ref.owner, ref.repo, client_opts(creds)) do
      {:ok, Enum.map(prs, &normalize_pr/1)}
    end
  end

  @impl true
  def list_pipeline_runs(creds, ref, head_sha) do
    opts = client_opts(creds) ++ [head_sha: head_sha]

    with {:ok, runs} <- Client.list_workflow_runs(ref.owner, ref.repo, opts) do
      {:ok, Enum.map(runs, &normalize_pipeline_run/1)}
    end
  end

  @impl true
  def get_pipeline_logs(creds, ref, run_id) do
    Client.get_workflow_run_logs(ref.owner, ref.repo, run_id, client_opts(creds))
  end

  @impl true
  def create_comment(creds, ref, issue_number, body) do
    Client.create_issue_comment(ref.owner, ref.repo, issue_number, body, client_opts(creds))
  end

  @impl true
  def create_review(creds, ref, pr_number, body, opts) do
    Client.create_pull_request_review(ref.owner, ref.repo, pr_number, body, client_opts(creds) ++ opts)
  end

  @impl true
  def list_change_request_comments(creds, ref, issue_number) do
    Client.list_issue_comments(ref.owner, ref.repo, issue_number, client_opts(creds))
  end

  @list_threads_query """
  query($owner:String!,$repo:String!,$number:Int!){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$number){
        reviewThreads(first:100){
          nodes{ id isResolved path line
            comments(first:100){ nodes{ id author{login} body createdAt } } }
        }
      }
    }
  }
  """

  @reply_mutation """
  mutation($threadId:ID!,$body:String!){
    addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$threadId,body:$body}){ comment{ id } }
  }
  """

  @resolve_mutation """
  mutation($threadId:ID!){ resolveReviewThread(input:{threadId:$threadId}){ thread{ id } } }
  """

  @impl true
  def list_review_threads(creds, ref, change_id) do
    vars = %{"owner" => ref.owner, "repo" => ref.repo, "number" => change_id}

    with {:ok, data} <- Client.graphql(@list_threads_query, vars, client_opts(creds)) do
      nodes = get_in(data, ["repository", "pullRequest", "reviewThreads", "nodes"]) || []
      {:ok, Enum.map(nodes, &normalize_thread/1)}
    end
  end

  @impl true
  def reply_to_review_thread(creds, _ref, _change_id, thread_id, body) do
    vars = %{"threadId" => thread_id, "body" => body}

    case Client.graphql(@reply_mutation, vars, client_opts(creds)) do
      {:ok, _data} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def resolve_review_thread(creds, _ref, _change_id, thread_id) do
    case Client.graphql(@resolve_mutation, %{"threadId" => thread_id}, client_opts(creds)) do
      {:ok, _data} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Private helpers ---

  defp normalize_thread(node) do
    comments =
      (get_in(node, ["comments", "nodes"]) || [])
      |> Enum.map(fn c ->
        %{id: c["id"], author: get_in(c, ["author", "login"]), body: c["body"], created_at: c["createdAt"]}
      end)

    %{
      id: node["id"],
      path: node["path"],
      line: node["line"],
      resolved: node["isResolved"] == true,
      author: comments |> List.first() |> then(&(&1 && &1.author)),
      comments: comments,
      last_comment_at: comments |> List.last() |> then(&(&1 && &1.created_at))
    }
  end

  defp client_opts(creds) do
    []
    |> put_if(creds[:token], :token)
    |> put_if(creds[:base_url], :base_url)
    |> put_if(creds[:request_fun], :request_fun)
    |> put_if(creds[:org], :org)
  end

  defp put_if(opts, nil, _key), do: opts
  defp put_if(opts, value, key), do: Keyword.put(opts, key, value)

  defp normalize_repo(body) do
    %{
      owner: get_in(body, ["owner", "login"]),
      name: body["name"],
      default_branch: body["default_branch"],
      url: body["html_url"]
    }
  end

  # `list_open_pull_requests` returns `PullRequest` structs which already carry
  # head_sha, head_ref, base_ref, number and url — map directly from the struct.
  defp normalize_pr(%SymphonyElixir.Github.PullRequest{} = pr) do
    %{
      number: pr.number,
      head_sha: pr.head_sha,
      head_ref: pr.head_ref,
      base_ref: pr.base_ref,
      url: pr.url
    }
  end

  defp normalize_pipeline_run(%SymphonyElixir.Github.WorkflowRun{} = run) do
    %{
      id: run.id,
      name: run.name,
      status: run.status,
      conclusion: run.conclusion,
      head_sha: run.head_sha
    }
  end
end
