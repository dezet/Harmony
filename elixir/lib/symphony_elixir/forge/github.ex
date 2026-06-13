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

  # --- Private helpers ---

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
