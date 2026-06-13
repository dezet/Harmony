defmodule SymphonyElixir.Forge.Gitlab do
  @moduledoc """
  Forge adapter for GitLab (gitlab.com and self-hosted).

  Accepts creds as a map with optional keys: `:token`, `:base_url`
  (the GitLab `instance_url`), `:request_fun` (test injection).
  """

  @behaviour SymphonyElixir.Forge

  alias SymphonyElixir.Gitlab.Client

  @impl true
  def list_repositories(creds, _opts) do
    with {:ok, projects} <- Client.list_projects(client_opts(creds)) do
      {:ok, Enum.map(projects, &normalize_repo/1)}
    end
  end

  @impl true
  def get_repository(creds, owner, repo) do
    with {:ok, body} <- Client.get_project(owner, repo, client_opts(creds)) do
      {:ok, normalize_repo(body)}
    end
  end

  @impl true
  def list_change_requests(creds, ref, _opts) do
    with {:ok, mrs} <- Client.list_open_merge_requests(ref.owner, ref.repo, client_opts(creds)) do
      {:ok, Enum.map(mrs, &normalize_mr/1)}
    end
  end

  @impl true
  def list_pipeline_runs(creds, ref, head_sha) do
    with {:ok, pipelines} <- Client.list_pipelines(ref.owner, ref.repo, client_opts(creds) ++ [sha: head_sha]) do
      {:ok, Enum.map(pipelines, &normalize_pipeline/1)}
    end
  end

  @impl true
  def get_pipeline_logs(creds, ref, pipeline_id) do
    opts = client_opts(creds)

    with {:ok, jobs} <- Client.list_pipeline_jobs(ref.owner, ref.repo, pipeline_id, opts) do
      traces =
        jobs
        |> Enum.filter(&(&1.status == "failed"))
        |> Enum.map(fn job ->
          case Client.get_job_trace(ref.owner, ref.repo, job.id, opts) do
            {:ok, trace} -> "== job #{job.name} ==\n#{trace}"
            {:error, reason} -> "== job #{job.name} (trace error: #{inspect(reason)}) =="
          end
        end)

      {:ok, Enum.join(traces, "\n\n")}
    end
  end

  @impl true
  def create_comment(creds, ref, mr_iid, body) do
    Client.create_merge_request_note(ref.owner, ref.repo, mr_iid, body, client_opts(creds))
  end

  @impl true
  def create_review(creds, ref, mr_iid, body, _opts) do
    Client.create_merge_request_note(ref.owner, ref.repo, mr_iid, body, client_opts(creds))
  end

  @impl true
  def list_change_request_comments(creds, ref, mr_iid) do
    Client.list_merge_request_notes(ref.owner, ref.repo, mr_iid, client_opts(creds))
  end

  # --- helpers ---

  defp client_opts(creds) do
    []
    |> put_if(creds[:token], :token)
    |> put_if(creds[:base_url], :base_url)
    |> put_if(creds[:request_fun], :request_fun)
  end

  defp put_if(opts, nil, _key), do: opts
  defp put_if(opts, value, key), do: Keyword.put(opts, key, value)

  defp normalize_repo(body) do
    %{
      owner: get_in(body, ["namespace", "full_path"]),
      name: body["path"],
      default_branch: body["default_branch"],
      url: body["web_url"]
    }
  end

  defp normalize_mr(%SymphonyElixir.Gitlab.MergeRequest{} = mr) do
    %{number: mr.number, head_sha: mr.head_sha, head_ref: mr.head_ref, base_ref: mr.base_ref, url: mr.url}
  end

  defp normalize_pipeline(%SymphonyElixir.Gitlab.Pipeline{} = p) do
    %{
      id: p.id,
      name: "pipeline ##{p.id}",
      status: if(p.status in ~w(success failed canceled skipped), do: "completed", else: p.status),
      conclusion: pipeline_conclusion(p.status),
      head_sha: p.sha
    }
  end

  defp pipeline_conclusion("success"), do: "success"
  defp pipeline_conclusion("failed"), do: "failure"
  defp pipeline_conclusion("canceled"), do: "cancelled"
  defp pipeline_conclusion(_other), do: nil
end
