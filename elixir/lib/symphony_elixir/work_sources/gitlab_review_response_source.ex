defmodule SymphonyElixir.WorkSources.GitlabReviewResponseSource do
  @moduledoc "GitLab counterpart of GithubReviewResponseSource (capability a)."

  alias SymphonyElixir.Forge
  alias SymphonyElixir.Forge.ProjectCreds
  alias SymphonyElixir.Github
  alias SymphonyElixir.Gitlab
  alias SymphonyElixir.Review.Identity
  alias SymphonyElixir.Storage
  alias SymphonyElixir.WorkRun

  @max_attempts 3

  @spec fetch_candidates(map(), keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(project, opts \\ []) do
    ref = ProjectCreds.repo_ref(project)
    creds = ProjectCreds.creds(project, opts)
    client_opts = ProjectCreds.gitlab_client_opts(project, opts)

    owner = ref.owner || pv(project, :forge_owner)
    repo = ref.repo || pv(project, :forge_repo)

    identity =
      Keyword.get(opts, :harmony_identity) ||
        Identity.resolve(project, creds, current_user: fn c -> Forge.adapter(project).current_user(c) end)

    list_merge_requests =
      Keyword.get(opts, :list_pull_requests, fn o, r, _ ->
        Gitlab.Client.list_open_merge_requests(o, r, client_opts)
      end)

    list_review_threads =
      Keyword.get(opts, :list_review_threads, fn o, r, iid ->
        Forge.adapter(project).list_review_threads(
          creds,
          %{owner: o, repo: r, base_url: creds.base_url},
          iid
        )
      end)

    dedupe_status = Keyword.get(opts, :dedupe_status, &Storage.dedupe_status/2)
    attempt_count = Keyword.get(opts, :attempt_count, &Storage.review_attempt_count/2)

    dependencies = %{
      owner: owner,
      repo: repo,
      list_review_threads: list_review_threads,
      dedupe_status: dedupe_status,
      attempt_count: attempt_count,
      identity: identity
    }

    with {:ok, mrs} <- list_merge_requests.(owner, repo, []) do
      reduce_merge_requests(mrs, project, dependencies)
    end
  end

  defp reduce_merge_requests(mrs, project, dependencies) do
    Enum.reduce_while(mrs, {:ok, []}, fn mr, {:ok, runs} ->
      append_mr_candidates(mr, runs, project, dependencies)
    end)
  end

  defp append_mr_candidates(mr, runs, project, dependencies) do
    case candidates_for_mr(project, mr, dependencies) do
      {:ok, new_runs} -> {:cont, {:ok, runs ++ new_runs}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp candidates_for_mr(project, mr, dependencies) do
    link = Github.LinkResolver.resolve(mr, team_keys: List.wrap(pv(project, :linear_team_key)))

    case link do
      nil -> {:ok, []}
      _link -> review_thread_candidates(project, mr, link, dependencies)
    end
  end

  defp review_thread_candidates(project, mr, link, dependencies) do
    case dependencies.list_review_threads.(dependencies.owner, dependencies.repo, mr.number) do
      {:ok, threads} ->
        {:ok, build_runs(project, mr, link, threads, dependencies)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_runs(project, mr, link, threads, dependencies) do
    project_id = pv(project, :id)
    actionable = actionable_threads(project_id, mr, threads, dependencies)

    if actionable == [], do: [], else: [build_run(project, mr, link, actionable, dependencies)]
  end

  defp actionable_threads(project_id, mr, threads, dependencies) do
    actionable =
      threads
      |> Enum.filter(&actionable_thread?(&1, dependencies.identity))
      |> Enum.reject(fn t ->
        # Skip a thread only when its key is terminal: processed (resolved/capped)
        # or already at the attempt cap. A mid-retry "claimed" row must NOT skip it,
        # or attempts 2..N would never run.
        key = dedupe_key(dependencies.owner, dependencies.repo, mr, t)

        dependencies.dedupe_status.(project_id, key) == "processed" or
          dependencies.attempt_count.(project_id, key) >= @max_attempts
      end)
      |> Enum.map(fn t ->
        Map.put(t, :dedupe_key, dedupe_key(dependencies.owner, dependencies.repo, mr, t))
      end)

    actionable
  end

  defp actionable_thread?(thread, identity), do: not thread.resolved and reviewer_latest?(thread, identity)

  defp reviewer_latest?(%{comments: comments}, identity) when is_list(comments) and comments != [],
    do: List.last(comments).author != identity

  defp reviewer_latest?(_thread, _identity), do: false

  defp build_run(project, mr, link, threads, dependencies) do
    %WorkRun{
      project_slug: pv(project, :slug),
      type: "address_review",
      status: "queued",
      dedupe_key: dedupe_key(dependencies.owner, dependencies.repo, mr, List.first(threads)),
      forge_type: "gitlab",
      forge_base_url: pv(project, :forge_base_url),
      forge_owner: dependencies.owner,
      forge_repo: dependencies.repo,
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
