defmodule SymphonyElixir.WorkSources.GithubPrSource do
  @moduledoc """
  Polls open GitHub PRs and records durable PR metadata.
  """

  alias SymphonyElixir.{Github, Storage, WorkRun}

  @spec fetch_candidates(term(), keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(project, opts \\ []) do
    list_pull_requests = Keyword.get(opts, :list_pull_requests, &Github.Client.list_open_pull_requests/3)
    owner = project_value(project, :github_owner)
    repo = project_value(project, :github_repo)

    with {:ok, prs} <- list_pull_requests.(owner, repo, []) do
      runs =
        Enum.map(prs, fn pr ->
          link = Github.LinkResolver.resolve(pr, team_keys: List.wrap(project_value(project, :linear_team_key)))
          persist_link(project, pr, link, opts)
          pr_to_candidate(project, pr, link)
        end)

      {:ok, runs}
    end
  end

  defp persist_link(project, pr, link, opts) do
    persist = Keyword.get(opts, :persist_link, &Storage.upsert_pull_request_link/1)

    persist.(%{
      project_id: project_value(project, :id),
      github_owner: project_value(project, :github_owner),
      github_repo: project_value(project, :github_repo),
      github_pr_number: pr.number,
      github_head_sha: pr.head_sha,
      linear_identifier: link && link.identifier,
      linear_url: link && link.url,
      metadata: %{"title" => pr.title}
    })
  end

  defp pr_to_candidate(project, pr, link) do
    %WorkRun{
      project_slug: project_value(project, :slug),
      type: "github_pr_observed",
      status: "observed",
      github_owner: project_value(project, :github_owner),
      github_repo: project_value(project, :github_repo),
      github_pr_number: pr.number,
      github_head_sha: pr.head_sha,
      github_head_ref: pr.head_ref,
      github_base_ref: pr.base_ref,
      linear_identifier: link && link.identifier,
      linear_url: link && link.url,
      agent_backend: "codex",
      payload: %{pull_request: pr}
    }
  end

  defp project_value(project, key) when is_map(project) do
    Map.get(project, key) || Map.get(project, to_string(key))
  end
end
