defmodule SymphonyElixir.WorkSources.GithubFailedCiSource do
  @moduledoc """
  Polls open GitHub PRs and emits failed GitHub Actions repair work.
  """

  alias SymphonyElixir.{Github, RuntimePolicy, Storage, WorkRun}
  alias SymphonyElixir.Forge.ProjectCreds

  @max_log_excerpt_bytes 12_000

  @spec fetch_candidates(term(), keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(project, opts \\ []) do
    ref = ProjectCreds.repo_ref(project)
    client_opts = ProjectCreds.client_opts(project, opts)

    list_pull_requests =
      Keyword.get(opts, :list_pull_requests, fn owner, repo, _call_opts ->
        Github.Client.list_open_pull_requests(owner, repo, client_opts)
      end)

    list_workflow_runs =
      Keyword.get(opts, :list_workflow_runs, fn owner, repo, call_opts ->
        Github.Client.list_workflow_runs(owner, repo, client_opts ++ call_opts)
      end)

    get_workflow_run_logs =
      Keyword.get(opts, :get_workflow_run_logs, fn owner, repo, run_id, _call_opts ->
        Github.Client.get_workflow_run_logs(owner, repo, run_id, client_opts)
      end)

    dedupe_seen? = Keyword.get(opts, :dedupe_seen?, &Storage.dedupe_seen?/2)

    owner = ref.owner || project_value(project, :github_owner)
    repo = ref.repo || project_value(project, :github_repo)

    with {:ok, prs} <- list_pull_requests.(owner, repo, []) do
      prs
      |> Enum.reduce_while({:ok, []}, fn pr, {:ok, runs} ->
        append_failed_ci_candidates(
          project,
          owner,
          repo,
          list_workflow_runs,
          get_workflow_run_logs,
          dedupe_seen?,
          pr,
          runs
        )
      end)
    end
  end

  defp append_failed_ci_candidates(project, owner, repo, list_workflow_runs, get_workflow_run_logs, dedupe_seen?, pr, runs) do
    case list_workflow_runs.(owner, repo, head_sha: pr.head_sha) do
      {:ok, workflow_runs} ->
        candidates = failed_ci_candidates(project, owner, repo, pr, workflow_runs, get_workflow_run_logs, dedupe_seen?)
        {:cont, {:ok, runs ++ candidates}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp failed_ci_candidates(project, owner, repo, pr, workflow_runs, get_workflow_run_logs, dedupe_seen?) do
    workflow_runs
    |> Enum.filter(&failed_actions_run?/1)
    |> Enum.reject(fn workflow_run ->
      dedupe_seen?.(project_value(project, :id), dedupe_key(owner, repo, pr, workflow_run))
    end)
    |> Enum.map(&build_run(project, owner, repo, pr, &1, get_workflow_run_logs))
  end

  defp build_run(project, owner, repo, pr, workflow_run, get_workflow_run_logs) do
    link = Github.LinkResolver.resolve(pr, team_keys: List.wrap(project_value(project, :linear_team_key)))
    repo_policy = repo_policy(project, pr)
    log_payload = workflow_run_log_payload(owner, repo, workflow_run, get_workflow_run_logs)

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
      payload:
        %{
          project_id: project_value(project, :id),
          pull_request: pr,
          workflow_run: workflow_run,
          repo_policy: repo_policy
        }
        |> Map.merge(log_payload)
    }
  end

  defp workflow_run_log_payload(owner, repo, workflow_run, get_workflow_run_logs) do
    case get_workflow_run_logs.(owner, repo, workflow_run.id, []) do
      {:ok, logs} when is_binary(logs) ->
        %{log_excerpt: excerpt(logs)}

      {:error, reason} ->
        %{log_fetch_error: inspect(reason)}

      other ->
        %{log_fetch_error: inspect({:unexpected_log_result, other})}
    end
  end

  defp excerpt(logs) when byte_size(logs) <= @max_log_excerpt_bytes, do: logs

  defp excerpt(logs) do
    binary_part(logs, 0, @max_log_excerpt_bytes) <> "\n[truncated]"
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
