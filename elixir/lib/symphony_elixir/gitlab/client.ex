defmodule SymphonyElixir.Gitlab.Client do
  @moduledoc "Minimal GitLab REST v4 client for Harmony MR/pipeline polling."

  alias SymphonyElixir.Forge.ArchiveRedirect
  alias SymphonyElixir.Forge.ArchiveStream
  alias SymphonyElixir.Gitlab.{Job, MergeRequest, Note, Pipeline}

  @default_host "https://gitlab.com"
  @max_archive_bytes 100 * 1024 * 1024
  @archive_stream_key :symphony_elixir_archive_stream

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

  @spec get_repository_branch_sha(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def get_repository_branch_sha(owner, repo, branch, opts \\ []) do
    path =
      "/projects/#{project_path(owner, repo)}/repository/branches/#{URI.encode_www_form(branch)}"

    with {:ok, body} <- get(opts, path, parse: & &1),
         sha when is_binary(sha) and sha != "" <- get_in(body, ["commit", "id"]) do
      {:ok, sha}
    else
      nil -> {:error, :gitlab_commit_sha_missing}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :gitlab_commit_sha_missing}
    end
  end

  @spec get_repository_archive(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def get_repository_archive(owner, repo, sha, opts \\ []) do
    path = "/projects/#{project_path(owner, repo)}/repository/archive.tar.gz"
    get_binary(opts, path, params: [sha: sha])
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

  @spec list_merge_request_notes(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, [Note.t()]} | {:error, term()}
  def list_merge_request_notes(owner, repo, mr_iid, opts \\ []) do
    get(opts, "/projects/#{project_path(owner, repo)}/merge_requests/#{mr_iid}/notes",
      params: [per_page: 100],
      parse: &Enum.map(&1, fn raw -> Note.from_api(raw) end)
    )
  end

  @spec create_merge_request_note(String.t(), String.t(), pos_integer(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def create_merge_request_note(owner, repo, mr_iid, body, opts \\ []) when is_binary(body) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    url = "#{api_root(opts)}/projects/#{project_path(owner, repo)}/merge_requests/#{mr_iid}/notes"

    case request_fun.(method: :post, url: url, json: %{body: body}, headers: headers(token(opts))) do
      {:ok, response} -> expect_status(response, [200, 201])
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_merge_request_discussions(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_merge_request_discussions(owner, repo, mr_iid, opts \\ []) do
    get(opts, "/projects/#{project_path(owner, repo)}/merge_requests/#{mr_iid}/discussions",
      params: [per_page: 100],
      parse: & &1
    )
  end

  @spec reply_to_discussion(String.t(), String.t(), pos_integer(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def reply_to_discussion(owner, repo, mr_iid, discussion_id, body, opts \\ []) when is_binary(body) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)

    url =
      "#{api_root(opts)}/projects/#{project_path(owner, repo)}/merge_requests/#{mr_iid}/discussions/#{discussion_id}/notes"

    case request_fun.(method: :post, url: url, json: %{body: body}, headers: headers(token(opts))) do
      {:ok, response} -> expect_status(response, [200, 201])
      {:error, reason} -> {:error, reason}
    end
  end

  @spec resolve_discussion(String.t(), String.t(), pos_integer(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def resolve_discussion(owner, repo, mr_iid, discussion_id, opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)

    url =
      "#{api_root(opts)}/projects/#{project_path(owner, repo)}/merge_requests/#{mr_iid}/discussions/#{discussion_id}"

    case request_fun.(method: :put, url: url, params: [resolved: true], headers: headers(token(opts))) do
      {:ok, response} -> expect_status(response, [200, 201])
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_authenticated_user(keyword()) :: {:ok, map()} | {:error, term()}
  def get_authenticated_user(opts \\ []) do
    get(opts, "/user", parse: & &1)
  end

  # --- shared GET ---

  defp get_binary(opts, path, call_opts) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)

    req = [
      method: :get,
      url: "#{api_root(opts)}#{path}",
      headers: archive_headers(token(opts)),
      params: Keyword.fetch!(call_opts, :params),
      retry: false,
      raw: true,
      into: ArchiveStream.into(@max_archive_bytes, @archive_stream_key)
    ]

    with {:ok, response} <- ArchiveRedirect.fetch(req, request_fun, @archive_stream_key),
         :ok <- check_archive_size(response),
         :ok <- expect_archive_status(response),
         {:ok, archive} <- archive_body(response) do
      {:ok, archive}
    end
  end

  defp check_archive_size(%{private: %{@archive_stream_key => %{too_large?: true}}}),
    do: {:error, :gitlab_archive_response_too_large}

  defp check_archive_size(%{body: body}) when is_binary(body) and byte_size(body) > @max_archive_bytes,
    do: {:error, :gitlab_archive_response_too_large}

  defp check_archive_size(_response), do: :ok

  defp expect_archive_status(%{status: 200}), do: :ok
  defp expect_archive_status(%{status: status}), do: {:error, {:gitlab_status, status}}

  defp archive_body(%{private: %{@archive_stream_key => %{chunks: chunks}}}) do
    {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp archive_body(%{body: body}) when is_binary(body) and byte_size(body) <= @max_archive_bytes,
    do: {:ok, body}

  defp archive_body(_response), do: {:error, :gitlab_archive_body_invalid}

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

  defp archive_headers(token) when is_binary(token) and token != "" do
    [{"private-token", token}, {"accept", "application/gzip, application/octet-stream"}]
  end

  defp archive_headers(_token), do: [{"accept", "application/gzip, application/octet-stream"}]

  defp headers(token) when is_binary(token) and token != "", do: [{"private-token", token}, {"accept", "application/json"}]
  defp headers(_token), do: [{"accept", "application/json"}]

  defp expect_status(%{status: status}, expected) when is_list(expected) do
    if status in expected, do: :ok, else: {:error, {:gitlab_status, status}}
  end

  defp expect_status(%{status: status}, expected) when status == expected, do: :ok
  defp expect_status(%{status: status, body: body}, _expected), do: {:error, {:gitlab_status, status, body}}
end
