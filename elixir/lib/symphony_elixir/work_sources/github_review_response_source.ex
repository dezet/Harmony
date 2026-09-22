defmodule SymphonyElixir.WorkSources.GithubReviewResponseSource do
  @moduledoc """
  Polls open PRs Harmony opened and emits `address_review` work for unresolved
  review threads whose newest comment is from a reviewer (capability a).
  """

  alias SymphonyElixir.Forge
  alias SymphonyElixir.Forge.ProjectCreds
  alias SymphonyElixir.Github
  alias SymphonyElixir.Review.Identity
  alias SymphonyElixir.Storage
  alias SymphonyElixir.WorkRun

  @max_attempts 3

  @spec fetch_candidates(map(), keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(project, opts \\ []) do
    ref = ProjectCreds.repo_ref(project)
    creds = ProjectCreds.creds(project, opts)
    client_opts = ProjectCreds.client_opts(project, opts)

    owner = ref.owner || pv(project, :forge_owner)
    repo = ref.repo || pv(project, :forge_repo)

    identity =
      Keyword.get(opts, :harmony_identity) ||
        Identity.resolve(project, creds, current_user: fn c -> Forge.adapter(project).current_user(c) end)

    list_pull_requests =
      Keyword.get(opts, :list_pull_requests, fn o, r, _ ->
        Github.Client.list_open_pull_requests(o, r, client_opts)
      end)

    list_review_threads =
      Keyword.get(opts, :list_review_threads, fn o, r, number ->
        Forge.adapter(project).list_review_threads(
          creds,
          %{owner: o, repo: r, base_url: creds.base_url},
          number
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

    with {:ok, prs} <- list_pull_requests.(owner, repo, []) do
      reduce_pull_requests(prs, project, dependencies)
    end
  end

  defp reduce_pull_requests(prs, project, dependencies) do
    Enum.reduce_while(prs, {:ok, []}, fn pr, {:ok, runs} ->
      append_pr_candidates(pr, runs, project, dependencies)
    end)
  end

  defp append_pr_candidates(pr, runs, project, dependencies) do
    case candidates_for_pr(project, pr, dependencies) do
      {:ok, new_runs} -> {:cont, {:ok, runs ++ new_runs}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp candidates_for_pr(project, pr, dependencies) do
    link = Github.LinkResolver.resolve(pr, team_keys: List.wrap(pv(project, :linear_team_key)))

    case link do
      nil -> {:ok, []}
      _link -> review_thread_candidates(project, pr, link, dependencies)
    end
  end

  defp review_thread_candidates(project, pr, link, dependencies) do
    case dependencies.list_review_threads.(dependencies.owner, dependencies.repo, pr.number) do
      {:ok, threads} ->
        {:ok, build_runs(project, pr, link, threads, dependencies)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_runs(project, pr, link, threads, dependencies) do
    project_id = pv(project, :id)
    actionable = actionable_threads(project_id, pr, threads, dependencies)

    if actionable == [] do
      []
    else
      [build_run(project, pr, link, actionable, dependencies)]
    end
  end

  defp actionable_threads(project_id, pr, threads, dependencies) do
    actionable =
      threads
      |> Enum.filter(&actionable_thread?(&1, dependencies.identity))
      |> Enum.reject(fn t ->
        # Skip a thread only when its key is terminal: processed (resolved/capped)
        # or already at the attempt cap. A mid-retry "claimed" row must NOT skip it,
        # or attempts 2..N would never run.
        key = dedupe_key(dependencies.owner, dependencies.repo, pr, t)

        dependencies.dedupe_status.(project_id, key) == "processed" or
          dependencies.attempt_count.(project_id, key) >= @max_attempts
      end)
      |> Enum.map(fn t ->
        Map.put(t, :dedupe_key, dedupe_key(dependencies.owner, dependencies.repo, pr, t))
      end)

    actionable
  end

  defp actionable_thread?(thread, identity) do
    not thread.resolved and reviewer_latest?(thread, identity)
  end

  defp reviewer_latest?(%{comments: comments}, identity) when is_list(comments) and comments != [] do
    List.last(comments).author != identity
  end

  defp reviewer_latest?(_thread, _identity), do: false

  defp build_run(project, pr, link, threads, dependencies) do
    %WorkRun{
      project_slug: pv(project, :slug),
      type: "address_review",
      status: "queued",
      dedupe_key: dedupe_key(dependencies.owner, dependencies.repo, pr, List.first(threads)),
      forge_owner: dependencies.owner,
      forge_repo: dependencies.repo,
      forge_pr_number: pr.number,
      forge_head_sha: pr.head_sha,
      forge_head_ref: pr.head_ref,
      forge_base_ref: pr.base_ref,
      linear_identifier: link.identifier,
      linear_url: link.url,
      agent_backend: "codex",
      payload: %{
        "project_id" => pv(project, :id),
        "pull_request" => pr,
        "threads" => threads
      }
    }
  end

  defp dedupe_key(owner, repo, pr, thread) do
    latest = thread.comments |> List.last() |> Map.get(:id)
    "review-response:#{owner}/#{repo}:#{pr.number}:#{thread.id}:#{latest}"
  end

  defp pv(project, key) when is_map(project), do: Map.get(project, key) || Map.get(project, to_string(key))
end
