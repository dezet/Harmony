defmodule SymphonyElixir.WorkSources.GithubReviewRequestSource do
  @moduledoc """
  Polls open GitHub PRs and emits requested code review work.
  """

  alias SymphonyElixir.{Github, Storage, WorkRun}

  @default_trigger "@hreview"
  @default_template_version 1
  @default_template """
  Review correctness, tests, maintainability, security, and operational risk.
  Lead with findings ordered by severity. Include concrete file and line references when you can determine them.
  """

  @spec fetch_candidates(term(), keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(project, opts \\ []) do
    list_pull_requests = Keyword.get(opts, :list_pull_requests, &Github.Client.list_open_pull_requests/3)
    list_issue_comments = Keyword.get(opts, :list_issue_comments, &Github.Client.list_issue_comments/4)
    dedupe_seen? = Keyword.get(opts, :dedupe_seen?, &Storage.dedupe_seen?/2)

    owner = project_value(project, :github_owner)
    repo = project_value(project, :github_repo)

    with {:ok, prs} <- list_pull_requests.(owner, repo, []) do
      prs
      |> Enum.reduce_while({:ok, []}, fn pr, {:ok, runs} ->
        append_review_candidates(project, owner, repo, list_issue_comments, dedupe_seen?, pr, runs)
      end)
    end
  end

  defp append_review_candidates(project, owner, repo, list_issue_comments, dedupe_seen?, pr, runs) do
    case list_issue_comments.(owner, repo, pr.number, []) do
      {:ok, comments} ->
        candidates = review_candidates(project, owner, repo, pr, comments, dedupe_seen?)
        {:cont, {:ok, runs ++ candidates}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp review_candidates(project, owner, repo, pr, comments, dedupe_seen?) do
    comments
    |> Enum.filter(&trigger_comment?(&1, project))
    |> Enum.reject(fn comment ->
      dedupe_seen?.(project_value(project, :id), dedupe_key(owner, repo, pr, comment, project))
    end)
    |> Enum.map(&build_run(project, owner, repo, pr, &1))
  end

  defp build_run(project, owner, repo, pr, comment) do
    link = Github.LinkResolver.resolve(pr, team_keys: List.wrap(project_value(project, :linear_team_key)))

    %WorkRun{
      project_slug: project_value(project, :slug),
      type: "code_review",
      status: "queued",
      dedupe_key: dedupe_key(owner, repo, pr, comment, project),
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
        trigger_comment: comment,
        trigger_comment_id: comment.id,
        trigger_comment_author: comment.author,
        trigger: review_trigger(project),
        template: review_template(project),
        template_version: review_template_version(project)
      }
    }
  end

  defp trigger_comment?(%{body: body}, project) when is_binary(body) do
    String.contains?(body, review_trigger(project))
  end

  defp trigger_comment?(_comment, _project), do: false

  defp dedupe_key(owner, repo, pr, comment, project) do
    "github-review:#{owner}/#{repo}:#{pr.number}:#{comment.id}:#{pr.head_sha}:#{review_template_version(project)}"
  end

  defp review_trigger(project) do
    project
    |> review_config()
    |> map_get_any(:trigger)
    |> case do
      trigger when is_binary(trigger) and trigger != "" -> trigger
      _other -> @default_trigger
    end
  end

  defp review_template_version(project) do
    project
    |> review_config()
    |> map_get_any(:template_version)
    |> case do
      version when is_integer(version) and version > 0 -> version
      version when is_binary(version) -> parse_positive_integer(version, @default_template_version)
      _other -> @default_template_version
    end
  end

  defp review_template(project) do
    project
    |> review_config()
    |> map_get_any(:template)
    |> case do
      template when is_binary(template) and template != "" -> template
      _other -> @default_template
    end
  end

  defp review_config(project) do
    project
    |> project_value(:config)
    |> map_get_any(:review)
    |> case do
      config when is_map(config) -> config
      _other -> %{}
    end
  end

  defp parse_positive_integer(value, default) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> default
    end
  end

  defp project_value(project, key) when is_map(project) do
    Map.get(project, key) || Map.get(project, to_string(key))
  end

  defp map_get_any(%{} = map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_get_any(_map, _key), do: nil
end
