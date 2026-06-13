defmodule SymphonyElixir.WorkSources.GithubPrSource do
  @moduledoc """
  Polls open GitHub PRs and records durable PR metadata.
  """

  alias SymphonyElixir.{Github, Storage, WorkRun}
  alias SymphonyElixir.Forge.ProjectCreds

  @spec fetch_candidates(term(), keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(project, opts \\ []) do
    ref = ProjectCreds.repo_ref(project)
    client_opts = ProjectCreds.client_opts(project, opts)

    list_pull_requests =
      Keyword.get(opts, :list_pull_requests, fn owner, repo, _call_opts ->
        Github.Client.list_open_pull_requests(owner, repo, client_opts)
      end)

    owner = ref.owner || project_value(project, :forge_owner)
    repo = ref.repo || project_value(project, :forge_repo)

    with {:ok, prs} <- list_pull_requests.(owner, repo, []) do
      runs =
        Enum.map(prs, fn pr ->
          link = Github.LinkResolver.resolve(pr, team_keys: List.wrap(project_value(project, :linear_team_key)))
          persist_link(project, pr, link, owner, repo, opts)
          pr_to_candidate(project, pr, link, owner, repo)
        end)

      {:ok, runs}
    end
  end

  defp persist_link(project, pr, link, owner, repo, opts) do
    persist = Keyword.get(opts, :persist_link, &Storage.upsert_pull_request_link/1)

    persist.(%{
      project_id: project_value(project, :id),
      forge_owner: owner,
      forge_repo: repo,
      forge_pr_number: pr.number,
      forge_head_sha: pr.head_sha,
      forge_head_ref: pr.head_ref,
      forge_base_ref: pr.base_ref,
      linear_identifier: link && link.identifier,
      linear_url: link && link.url,
      metadata: %{"title" => pr.title}
    })
  end

  defp pr_to_candidate(project, pr, link, owner, repo) do
    %WorkRun{
      project_slug: project_value(project, :slug),
      type: "github_pr_observed",
      status: "observed",
      forge_owner: owner,
      forge_repo: repo,
      forge_pr_number: pr.number,
      forge_head_sha: pr.head_sha,
      forge_head_ref: pr.head_ref,
      forge_base_ref: pr.base_ref,
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
