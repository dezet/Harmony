defmodule SymphonyElixir.WorkSources.GithubFailedCiSource do
  @moduledoc """
  Polls open GitHub PRs and emits failed GitHub Actions repair work.
  """

  alias SymphonyElixir.{Github, RuntimePolicy, Storage, WorkRun}

  @spec fetch_candidates(term(), keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(project, opts \\ []) do
    list_pull_requests = Keyword.get(opts, :list_pull_requests, &Github.Client.list_open_pull_requests/3)
    list_workflow_runs = Keyword.get(opts, :list_workflow_runs, &Github.Client.list_workflow_runs/3)
    dedupe_seen? = Keyword.get(opts, :dedupe_seen?, &Storage.dedupe_seen?/2)

    owner = project_value(project, :github_owner)
    repo = project_value(project, :github_repo)

    with {:ok, prs} <- list_pull_requests.(owner, repo, []) do
      prs
      |> Enum.reduce_while({:ok, []}, fn pr, {:ok, runs} ->
        append_failed_ci_candidates(project, owner, repo, list_workflow_runs, dedupe_seen?, pr, runs)
      end)
    end
  end

  defp append_failed_ci_candidates(project, owner, repo, list_workflow_runs, dedupe_seen?, pr, runs) do
    case list_workflow_runs.(owner, repo, head_sha: pr.head_sha) do
      {:ok, workflow_runs} ->
        candidates = failed_ci_candidates(project, owner, repo, pr, workflow_runs, dedupe_seen?)
        {:cont, {:ok, runs ++ candidates}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp failed_ci_candidates(project, owner, repo, pr, workflow_runs, dedupe_seen?) do
    workflow_runs
    |> Enum.filter(&failed_actions_run?/1)
    |> Enum.reject(fn workflow_run ->
      dedupe_seen?.(project_value(project, :id), dedupe_key(owner, repo, pr, workflow_run))
    end)
    |> Enum.map(&build_run(project, owner, repo, pr, &1))
  end

  defp build_run(project, owner, repo, pr, workflow_run) do
    link = Github.LinkResolver.resolve(pr, team_keys: List.wrap(project_value(project, :linear_team_key)))
    repo_policy = repo_policy(project, pr)

    %WorkRun{
      project_slug: project_value(project, :slug),
      type: "ci_fix",
      status: "queued",
      dedupe_key: dedupe_key(owner, repo, pr, workflow_run),
      github_owner: owner,
      github_repo: repo,
      github_pr_number: pr.number,
      github_head_sha: pr.head_sha,
      github_head_ref: pr.head_ref,
      github_base_ref: pr.base_ref,
      linear_identifier: link && link.identifier,
      linear_url: link && link.url,
      agent_backend: "codex",
      payload: %{
        project_id: project_value(project, :id),
        pull_request: pr,
        workflow_run: workflow_run,
        repo_policy: repo_policy
      }
    }
  end

  defp repo_policy(project, pr) do
    case RuntimePolicy.RepoPolicy.authorize_push(%{
           head_repo_full_name: pr.head_repo_full_name,
           base_repo_full_name: pr.base_repo_full_name || "#{project_value(project, :github_owner)}/#{project_value(project, :github_repo)}",
           head_ref: pr.head_ref,
           base_ref: pr.base_ref || project_value(project, :github_base_branch),
           protected_branches: protected_branches(project)
         }) do
      :ok -> "direct_push_allowed"
      {:error, :fork_pr_requires_repair_branch} -> "repair_branch_required"
      {:error, reason} -> "blocked:#{reason}"
    end
  end

  defp protected_branches(project) do
    config = project_value(project, :config) || %{}

    config
    |> map_get_any(:protected_branches)
    |> case do
      branches when is_list(branches) -> branches
      _other -> List.wrap(project_value(project, :github_base_branch))
    end
  end

  defp map_get_any(%{} = map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_get_any(_map, _key), do: nil

  defp dedupe_key(owner, repo, pr, workflow_run) do
    "github-ci-fix:#{owner}/#{repo}:#{pr.number}:#{pr.head_sha}:#{workflow_run.id}"
  end

  defp failed_actions_run?(%{status: "completed", conclusion: "failure"}), do: true
  defp failed_actions_run?(_run), do: false

  defp project_value(project, key) when is_map(project) do
    Map.get(project, key) || Map.get(project, to_string(key))
  end
end
