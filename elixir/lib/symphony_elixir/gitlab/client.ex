defmodule SymphonyElixir.Gitlab.Client do
  @moduledoc "Minimal GitLab REST v4 client for Harmony MR/pipeline polling."

  alias SymphonyElixir.Gitlab.{MergeRequest, Pipeline, Job, Note}

  @default_host "https://gitlab.com"

  defp api_root(opts), do: "#{Keyword.get(opts, :base_url) || @default_host}/api/v4"
  defp project_path(owner, repo), do: URI.encode_www_form("#{owner}/#{repo}")

  @spec list_projects(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_projects(opts \\ []) do
    get(opts, "/projects", params: [membership: true, per_page: 100], parse: & &1)
  end

  @spec get_project(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_project(owner, repo, opts \\ []) do
    get(opts, "/projects/#{project_path(owner, repo)}", parse: & &1)
  end

  @spec list_open_merge_requests(String.t(), String.t(), keyword()) :: {:ok, [MergeRequest.t()]} | {:error, term()}
  def list_open_merge_requests(owner, repo, opts \\ []) do
    get(opts, "/projects/#{project_path(owner, repo)}/merge_requests",
      params: [state: "opened", per_page: 100],
      parse: &Enum.map(&1, fn raw -> MergeRequest.from_api(raw) end)
    )
  end

  @spec list_pipelines(String.t(), String.t(), keyword()) :: {:ok, [Pipeline.t()]} | {:error, term()}
  def list_pipelines(owner, repo, opts \\ []) do
    params = [per_page: 100] ++ if(opts[:sha], do: [sha: opts[:sha]], else: [])

    get(opts, "/projects/#{project_path(owner, repo)}/pipelines",
      params: params,
      parse: &Enum.map(&1, fn raw -> Pipeline.from_api(raw) end)
    )
  end

  @spec list_pipeline_jobs(String.t(), String.t(), pos_integer(), keyword()) :: {:ok, [Job.t()]} | {:error, term()}
  def list_pipeline_jobs(owner, repo, pipeline_id, opts \\ []) do
    get(opts, "/projects/#{project_path(owner, repo)}/pipelines/#{pipeline_id}/jobs",
      params: [per_page: 100],
      parse: &Enum.map(&1, fn raw -> Job.from_api(raw) end)
    )
  end

  @spec get_job_trace(String.t(), String.t(), pos_integer(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_job_trace(owner, repo, job_id, opts \\ []) do
    get(opts, "/projects/#{project_path(owner, repo)}/jobs/#{job_id}/trace", parse: & &1)
  end

  @spec list_merge_request_notes(String.t(), String.t(), pos_integer(), keyword()) :: {:ok, [Note.t()]} | {:error, term()}
  def list_merge_request_notes(owner, repo, mr_iid, opts \\ []) do
    get(opts, "/projects/#{project_path(owner, repo)}/merge_requests/#{mr_iid}/notes",
      params: [per_page: 100],
      parse: &Enum.map(&1, fn raw -> Note.from_api(raw) end)
    )
  end

  @spec create_merge_request_note(String.t(), String.t(), pos_integer(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_merge_request_note(owner, repo, mr_iid, body, opts \\ []) when is_binary(body) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    url = "#{api_root(opts)}/projects/#{project_path(owner, repo)}/merge_requests/#{mr_iid}/notes"

    case request_fun.(method: :post, url: url, json: %{body: body}, headers: headers(token(opts))) do
      {:ok, response} -> expect_status(response, [200, 201])
      {:error, reason} -> {:error, reason}
    end
  end

  # --- shared GET ---

  defp get(opts, path, call_opts) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    parse = Keyword.fetch!(call_opts, :parse)
    req = [method: :get, url: "#{api_root(opts)}#{path}", headers: headers(token(opts))]
    req = if call_opts[:params], do: Keyword.put(req, :params, call_opts[:params]), else: req

    with {:ok, response} <- request_fun.(req),
         :ok <- expect_status(response, 200) do
      {:ok, parse.(response.body)}
    end
  end

  defp token(opts), do: Keyword.get(opts, :token) || System.get_env("GITLAB_TOKEN")

  defp headers(token) when is_binary(token) and token != "", do: [{"private-token", token}, {"accept", "application/json"}]
  defp headers(_token), do: [{"accept", "application/json"}]

  defp expect_status(%{status: status}, expected) when is_list(expected) do
    if status in expected, do: :ok, else: {:error, {:gitlab_status, status}}
  end

  defp expect_status(%{status: status}, expected) when status == expected, do: :ok
  defp expect_status(%{status: status, body: body}, _expected), do: {:error, {:gitlab_status, status, body}}
end
