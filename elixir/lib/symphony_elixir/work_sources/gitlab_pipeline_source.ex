defmodule SymphonyElixir.WorkSources.GitlabPipelineSource do
  @moduledoc "Polls open GitLab MRs and emits failed-pipeline repair work."

  alias SymphonyElixir.{Gitlab, Github, RuntimePolicy, Storage, WorkRun}
  alias SymphonyElixir.Forge.ProjectCreds

  @max_log_excerpt_bytes 12_000

  @spec fetch_candidates(term(), keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(project, opts \\ []) do
    ref = ProjectCreds.repo_ref(project)
    client_opts = ProjectCreds.gitlab_client_opts(project, opts)

    list_merge_requests =
      Keyword.get(opts, :list_merge_requests, fn owner, repo, _call_opts ->
        Gitlab.Client.list_open_merge_requests(owner, repo, client_opts)
      end)

    list_pipelines =
      Keyword.get(opts, :list_pipelines, fn owner, repo, call_opts ->
        Gitlab.Client.list_pipelines(owner, repo, client_opts ++ call_opts)
      end)

    get_pipeline_logs =
      Keyword.get(opts, :get_pipeline_logs, fn owner, repo, pipeline_id, _call_opts ->
        creds = %{
          token: client_opts[:token],
          base_url: client_opts[:base_url],
          request_fun: client_opts[:request_fun]
        }

        SymphonyElixir.Forge.Gitlab.get_pipeline_logs(
          creds,
          %{owner: owner, repo: repo, base_url: client_opts[:base_url]},
          pipeline_id
        )
      end)

    dedupe_seen? = Keyword.get(opts, :dedupe_seen?, &Storage.dedupe_seen?/2)

    owner = ref.owner || project_value(project, :forge_owner)
    repo = ref.repo || project_value(project, :forge_repo)

    with {:ok, mrs} <- list_merge_requests.(owner, repo, []) do
      Enum.reduce_while(mrs, {:ok, []}, fn mr, {:ok, runs} ->
        case list_pipelines.(owner, repo, sha: mr.head_sha) do
          {:ok, pipelines} ->
            candidates = candidates(project, owner, repo, mr, pipelines, get_pipeline_logs, dedupe_seen?)
            {:cont, {:ok, runs ++ candidates}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp candidates(project, owner, repo, mr, pipelines, get_pipeline_logs, dedupe_seen?) do
    pipelines
    |> Enum.filter(&(&1.status == "failed"))
    |> Enum.reject(&dedupe_seen?.(project_value(project, :id), dedupe_key(owner, repo, mr, &1)))
    |> Enum.map(&build_run(project, owner, repo, mr, &1, get_pipeline_logs))
  end

  defp build_run(project, owner, repo, mr, pipeline, get_pipeline_logs) do
    link = Github.LinkResolver.resolve(mr, team_keys: List.wrap(project_value(project, :linear_team_key)))

    %WorkRun{
      project_slug: project_value(project, :slug),
      type: "ci_fix",
      status: "queued",
      dedupe_key: dedupe_key(owner, repo, mr, pipeline),
      forge_owner: owner,
      forge_repo: repo,
      forge_pr_number: mr.number,
      forge_head_sha: mr.head_sha,
      forge_head_ref: mr.head_ref,
      forge_base_ref: mr.base_ref,
      linear_identifier: link && link.identifier,
      linear_url: link && link.url,
      agent_backend: "codex",
      payload:
        %{
          project_id: project_value(project, :id),
          merge_request: mr,
          pipeline: pipeline,
          repo_policy: repo_policy(project, mr)
        }
        |> Map.merge(log_payload(owner, repo, pipeline, get_pipeline_logs))
    }
  end

  defp log_payload(owner, repo, pipeline, get_pipeline_logs) do
    case get_pipeline_logs.(owner, repo, pipeline.id, []) do
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

  defp repo_policy(project, mr) do
    case RuntimePolicy.RepoPolicy.authorize_push(%{
           head_repo_full_name: mr.head_repo_full_name,
           base_repo_full_name:
             mr.base_repo_full_name ||
               "#{project_value(project, :forge_owner)}/#{project_value(project, :forge_repo)}",
           head_ref: mr.head_ref,
           base_ref: mr.base_ref || project_value(project, :forge_base_branch),
           protected_branches: List.wrap(project_value(project, :forge_base_branch))
         }) do
      :ok -> "direct_push_allowed"
      {:error, :fork_pr_requires_repair_branch} -> "repair_branch_required"
      {:error, reason} -> "blocked:#{reason}"
    end
  end

  defp dedupe_key(owner, repo, mr, pipeline) do
    "gitlab-ci-fix:#{owner}/#{repo}:#{mr.number}:#{mr.head_sha}:#{pipeline.id}"
  end

  defp project_value(project, key) when is_map(project) do
    Map.get(project, key) || Map.get(project, to_string(key))
  end
end
