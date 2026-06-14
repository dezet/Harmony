defmodule SymphonyElixir.WorkSources.GitlabReviewResponseSource do
  @moduledoc "GitLab counterpart of GithubReviewResponseSource (capability a)."

  alias SymphonyElixir.{Gitlab, Github, Storage, WorkRun}
  alias SymphonyElixir.Forge.ProjectCreds

  @default_identity "harmony"

  @spec fetch_candidates(map(), keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(project, opts \\ []) do
    ref = ProjectCreds.repo_ref(project)
    creds = ProjectCreds.creds(project, opts)
    client_opts = ProjectCreds.gitlab_client_opts(project, opts)

    owner = ref.owner || pv(project, :forge_owner)
    repo = ref.repo || pv(project, :forge_repo)
    identity = Keyword.get(opts, :harmony_identity, @default_identity)

    list_merge_requests =
      Keyword.get(opts, :list_pull_requests, fn o, r, _ ->
        Gitlab.Client.list_open_merge_requests(o, r, client_opts)
      end)

    list_review_threads =
      Keyword.get(opts, :list_review_threads, fn o, r, iid ->
        SymphonyElixir.Forge.adapter(project).list_review_threads(
          creds,
          %{owner: o, repo: r, base_url: creds.base_url},
          iid
        )
      end)

    dedupe_seen? = Keyword.get(opts, :dedupe_seen?, &Storage.dedupe_seen?/2)

    with {:ok, mrs} <- list_merge_requests.(owner, repo, []) do
      mrs
      |> Enum.reduce_while({:ok, []}, fn mr, {:ok, runs} ->
        case candidates_for_mr(project, owner, repo, mr, list_review_threads, dedupe_seen?, identity) do
          {:ok, new} -> {:cont, {:ok, runs ++ new}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp candidates_for_mr(project, owner, repo, mr, list_review_threads, dedupe_seen?, identity) do
    link = Github.LinkResolver.resolve(mr, team_keys: List.wrap(pv(project, :linear_team_key)))

    if is_nil(link) do
      {:ok, []}
    else
      case list_review_threads.(owner, repo, mr.number) do
        {:ok, threads} -> {:ok, build_runs(project, owner, repo, mr, link, threads, dedupe_seen?, identity)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp build_runs(project, owner, repo, mr, link, threads, dedupe_seen?, identity) do
    actionable =
      threads
      |> Enum.filter(&actionable_thread?(&1, identity))
      |> Enum.reject(fn t -> dedupe_seen?.(pv(project, :id), dedupe_key(owner, repo, mr, t)) end)

    if actionable == [], do: [], else: [build_run(project, owner, repo, mr, link, actionable)]
  end

  defp actionable_thread?(thread, identity), do: not thread.resolved and reviewer_latest?(thread, identity)

  defp reviewer_latest?(%{comments: comments}, identity) when is_list(comments) and comments != [],
    do: List.last(comments).author != identity

  defp reviewer_latest?(_thread, _identity), do: false

  defp build_run(project, owner, repo, mr, link, threads) do
    %WorkRun{
      project_slug: pv(project, :slug),
      type: "address_review",
      status: "queued",
      dedupe_key: dedupe_key(owner, repo, mr, List.last(threads)),
      forge_type: "gitlab",
      forge_base_url: pv(project, :forge_base_url),
      forge_owner: owner,
      forge_repo: repo,
      forge_pr_number: mr.number,
      forge_head_sha: mr.head_sha,
      forge_head_ref: mr.head_ref,
      forge_base_ref: mr.base_ref,
      linear_identifier: link.identifier,
      linear_url: link.url,
      agent_backend: "codex",
      payload: %{"project_id" => pv(project, :id), "pull_request" => mr, "threads" => threads}
    }
  end

  defp dedupe_key(owner, repo, mr, thread) do
    latest = thread.comments |> List.last() |> Map.get(:id)
    "review-response:#{owner}/#{repo}:#{mr.number}:#{thread.id}:#{latest}"
  end

  defp pv(project, key) when is_map(project), do: Map.get(project, key) || Map.get(project, to_string(key))
end
