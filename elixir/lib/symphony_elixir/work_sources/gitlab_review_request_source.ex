defmodule SymphonyElixir.WorkSources.GitlabReviewRequestSource do
  @moduledoc "Polls open GitLab MRs and emits requested code review work from MR notes."

  alias SymphonyElixir.{Gitlab, Github, Storage, WorkRun}
  alias SymphonyElixir.Forge.ProjectCreds

  @default_trigger "@hreview"
  @default_template_version 1
  @default_template """
  Review correctness, tests, maintainability, security, and operational risk.
  Lead with findings ordered by severity. Include concrete file and line references when you can determine them.
  """

  @spec fetch_candidates(term(), keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(project, opts \\ []) do
    ref = ProjectCreds.repo_ref(project)
    client_opts = ProjectCreds.gitlab_client_opts(project, opts)

    list_merge_requests =
      Keyword.get(opts, :list_merge_requests, fn owner, repo, _call_opts ->
        Gitlab.Client.list_open_merge_requests(owner, repo, client_opts)
      end)

    list_notes =
      Keyword.get(opts, :list_notes, fn owner, repo, mr_iid, _call_opts ->
        Gitlab.Client.list_merge_request_notes(owner, repo, mr_iid, client_opts)
      end)

    dedupe_seen? = Keyword.get(opts, :dedupe_seen?, &Storage.dedupe_seen?/2)

    owner = ref.owner || project_value(project, :forge_owner)
    repo = ref.repo || project_value(project, :forge_repo)

    with {:ok, mrs} <- list_merge_requests.(owner, repo, []) do
      mrs
      |> Enum.reduce_while({:ok, []}, fn mr, {:ok, runs} ->
        append_review_candidates(project, owner, repo, list_notes, dedupe_seen?, mr, runs)
      end)
    end
  end

  defp append_review_candidates(project, owner, repo, list_notes, dedupe_seen?, mr, runs) do
    case list_notes.(owner, repo, mr.number, []) do
      {:ok, notes} ->
        candidates = review_candidates(project, owner, repo, mr, notes, dedupe_seen?)
        {:cont, {:ok, runs ++ candidates}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp review_candidates(project, owner, repo, mr, notes, dedupe_seen?) do
    notes
    |> Enum.filter(&trigger_note?(&1, project))
    |> Enum.reject(fn note ->
      dedupe_seen?.(project_value(project, :id), dedupe_key(owner, repo, mr, note, project))
    end)
    |> Enum.map(&build_run(project, owner, repo, mr, &1))
  end

  defp build_run(project, owner, repo, mr, note) do
    link = Github.LinkResolver.resolve(mr, team_keys: List.wrap(project_value(project, :linear_team_key)))

    %WorkRun{
      project_slug: project_value(project, :slug),
      type: "code_review",
      status: "queued",
      dedupe_key: dedupe_key(owner, repo, mr, note, project),
      forge_type: "gitlab",
      forge_base_url: project_value(project, :forge_base_url),
      forge_owner: owner,
      forge_repo: repo,
      forge_pr_number: mr.number,
      forge_head_sha: mr.head_sha,
      forge_head_ref: mr.head_ref,
      forge_base_ref: mr.base_ref,
      linear_identifier: link && link.identifier,
      linear_url: link && link.url,
      agent_backend: "codex",
      payload: %{
        project_id: project_value(project, :id),
        merge_request: mr,
        trigger_comment: note,
        trigger_comment_id: note.id,
        trigger_comment_author: note.author,
        trigger: review_trigger(project),
        template: review_template(project),
        template_version: review_template_version(project)
      }
    }
  end

  defp trigger_note?(%{body: body}, project) when is_binary(body) do
    String.contains?(body, review_trigger(project))
  end

  defp trigger_note?(_note, _project), do: false

  defp dedupe_key(owner, repo, mr, note, project) do
    "gitlab-review:#{owner}/#{repo}:#{mr.number}:#{note.id}:#{mr.head_sha}:#{review_template_version(project)}"
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
