defmodule SymphonyElixir.WorkSources.GitlabMrSource do
  @moduledoc "Polls open GitLab merge requests and records durable MR metadata."

  alias SymphonyElixir.{Gitlab, Github, Storage, WorkRun}
  alias SymphonyElixir.Forge.ProjectCreds

  @spec fetch_candidates(term(), keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(project, opts \\ []) do
    ref = ProjectCreds.repo_ref(project)
    client_opts = ProjectCreds.gitlab_client_opts(project, opts)

    list_merge_requests =
      Keyword.get(opts, :list_merge_requests, fn owner, repo, _call_opts ->
        Gitlab.Client.list_open_merge_requests(owner, repo, client_opts)
      end)

    owner = ref.owner || project_value(project, :forge_owner)
    repo = ref.repo || project_value(project, :forge_repo)

    with {:ok, mrs} <- list_merge_requests.(owner, repo, []) do
      runs =
        Enum.map(mrs, fn mr ->
          link = Github.LinkResolver.resolve(mr, team_keys: List.wrap(project_value(project, :linear_team_key)))
          persist_link(project, mr, link, owner, repo, opts)
          mr_to_candidate(project, mr, link, owner, repo)
        end)

      {:ok, runs}
    end
  end

  defp persist_link(project, mr, link, owner, repo, opts) do
    persist = Keyword.get(opts, :persist_link, &Storage.upsert_pull_request_link/1)

    persist.(%{
      project_id: project_value(project, :id),
      forge_owner: owner,
      forge_repo: repo,
      forge_pr_number: mr.number,
      forge_head_sha: mr.head_sha,
      forge_head_ref: mr.head_ref,
      forge_base_ref: mr.base_ref,
      linear_identifier: link && link.identifier,
      linear_url: link && link.url,
      metadata: %{"title" => mr.title}
    })
  end

  defp mr_to_candidate(project, mr, link, owner, repo) do
    %WorkRun{
      project_slug: project_value(project, :slug),
      type: "gitlab_mr_observed",
      status: "observed",
      forge_owner: owner,
      forge_repo: repo,
      forge_pr_number: mr.number,
      forge_head_sha: mr.head_sha,
      forge_head_ref: mr.head_ref,
      forge_base_ref: mr.base_ref,
      linear_identifier: link && link.identifier,
      linear_url: link && link.url,
      agent_backend: "codex",
      payload: %{merge_request: mr}
    }
  end

  defp project_value(project, key) when is_map(project) do
    Map.get(project, key) || Map.get(project, to_string(key))
  end
end
