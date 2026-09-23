defmodule SymphonyElixir.ArchiveClientSecurityTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Forge.ArchiveRedirect
  alias SymphonyElixir.Forge.ArchiveStream
  alias SymphonyElixir.Forge.Github, as: GithubForge
  alias SymphonyElixir.Forge.Gitlab, as: GitlabForge
  alias SymphonyElixir.Github.Client, as: GithubClient
  alias SymphonyElixir.Gitlab.Client, as: GitlabClient

  @archive_limit 100 * 1024 * 1024
  @archive_stream_key :symphony_elixir_archive_stream

  test "rejects archive redirects that downgrade from HTTPS to HTTP for both forges" do
    for client <- [:github, :gitlab] do
      origin_host = origin_host(client)
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:archive_server_request, conn.host, Plug.Conn.get_req_header(conn, "authorization"), Plug.Conn.get_req_header(conn, "private-token")})

        if conn.host == origin_host do
          Req.Test.redirect(conn, external: "http://storage.example.com/archive.tar.gz")
        else
          Req.Test.text(conn, "synthetic archive")
        end
      end)

      result = run_archive_redirect(client, test_pid)

      assert {:error, :insecure_archive_redirect} = result
      assert_receive {:archive_server_request, ^origin_host, authorization, private_token}

      assert token_observed?(client, authorization ++ private_token)
      refute_receive {:archive_server_request, "storage.example.com", _auth, _private_token}, 50
    end
  end

  test "follows HTTPS storage redirects with no Forge token on the storage request" do
    for client <- [:github, :gitlab] do
      origin_host = origin_host(client)
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:archive_server_request, conn.host, Plug.Conn.get_req_header(conn, "authorization"), Plug.Conn.get_req_header(conn, "private-token")})

        if conn.host == origin_host do
          Req.Test.redirect(conn, external: "https://storage.example.com/archive.tar.gz?signature=synthetic")
        else
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "synthetic ")
          {:ok, conn} = Plug.Conn.chunk(conn, "archive")
          conn
        end
      end)

      result = run_archive_redirect(client, test_pid)

      assert_receive {:archive_request_options, ^origin_host, false, initial_headers}
      assert_receive {:archive_request_options, "storage.example.com", false, storage_headers}
      assert token_header_present?(client, initial_headers)
      refute token_header_present?(client, storage_headers)
      assert_receive {:archive_server_request, ^origin_host, origin_authorization, origin_private_token}
      assert token_observed?(client, origin_authorization ++ origin_private_token)
      assert_receive {:archive_server_request, "storage.example.com", [], []}
      assert_streamed_bytes(test_pid, 200, 17)
      assert {:ok, "synthetic archive"} = result
    end
  end

  test "rejects unsafe or malformed redirect URL components" do
    for client <- [:github, :gitlab],
        location <- [
          "https://user:pass@storage.example.com/archive",
          "https://storage.example.com/archive#fragment",
          "https://bad host.example/archive",
          "https://storage.example.com:bad/archive"
        ] do
      test_pid = self()
      origin_host = origin_host(client)

      Req.Test.stub(__MODULE__, fn conn ->
        if conn.host == origin_host,
          do: Req.Test.redirect(conn, external: location),
          else: Req.Test.text(conn, "synthetic archive")
      end)

      result = run_archive_redirect(client, test_pid)
      assert {:error, :invalid_archive_redirect} = result
    end
  end

  test "allows a self-hosted HTTPS archive storage endpoint without forwarding credentials" do
    origin_host = origin_host(:gitlab)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      if conn.host == origin_host do
        Req.Test.redirect(conn, external: "https://localhost:9443/archive.tar.gz")
      else
        send(test_pid, {:self_hosted_request, conn.host, Plug.Conn.get_req_header(conn, "private-token")})
        Req.Test.text(conn, "self-hosted archive")
      end
    end)

    result = run_archive_redirect(:gitlab, test_pid)

    assert {:ok, "self-hosted archive"} = result
    assert_receive {:self_hosted_request, "localhost", []}
    assert_receive {:archive_request_options, "localhost", false, headers}
    refute token_header_present?(:gitlab, headers)
  end

  test "caps manual archive redirect chains" do
    Process.put(:archive_redirect_count, 0)

    Req.Test.stub(__MODULE__, fn conn ->
      count = Process.get(:archive_redirect_count, 0) + 1
      Process.put(:archive_redirect_count, count)
      Req.Test.redirect(conn, to: "/hop/#{count}")
    end)

    request_fun = fn opts -> Req.request(Keyword.put(opts, :plug, {Req.Test, __MODULE__})) end

    result =
      GithubClient.get_repository_archive("owner", "repo", "sha",
        base_url: "https://api.github.example.com",
        token: "SYNTHETIC-GITHUB-TOKEN-CANARY",
        request_fun: request_fun
      )

    assert {:error, :archive_redirect_limit_exceeded} = result
    assert Process.get(:archive_redirect_count) == 6
    Process.delete(:archive_redirect_count)
  end

  test "handles multi-chunk 503 archive responses for both forges" do
    test_pid = self()

    for client <- [:github, :gitlab] do
      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 503)
        {:ok, conn} = Plug.Conn.chunk(conn, "service ")
        {:ok, conn} = Plug.Conn.chunk(conn, "unavailable")
        conn
      end)

      result =
        fetch_archive(client,
          base_url: "https://#{origin_host(client)}",
          token: token(client),
          request_fun: streaming_request_fun(test_pid)
        )

      assert {:error, {status_error, 503}} = result
      assert status_error in [:github_status, :gitlab_status]
      assert_streamed_bytes(test_pid, 503, byte_size("service unavailable"))
    end
  end

  @tag :oversized_archive_200
  test "halts 200 archive streams when a later chunk exceeds 100 MiB" do
    test_pid = self()
    first_chunk = :binary.copy("x", @archive_limit)

    for client <- [:github, :gitlab] do
      request_fun = fn opts ->
        assert opts[:redirect] == false
        assert opts[:retry] == false
        into = Keyword.fetch!(opts, :into)
        request = make_ref()
        response = %{status: 200, headers: %{}, body: [], private: %{}}

        {:cont, {request, response}} = into.({:data, first_chunk}, {request, response})
        {:halt, {^request, response}} = into.({:data, "overflow"}, {request, response})

        state = Map.fetch!(response.private, @archive_stream_key)

        send(test_pid, {
          :archive_200_stream_progress,
          client,
          state.too_large?,
          state.bytes,
          IO.iodata_length(response.body),
          length(state.chunks)
        })

        {:ok, response}
      end

      result =
        fetch_archive(client,
          base_url: "https://#{origin_host(client)}",
          token: token(client),
          request_fun: request_fun
        )

      expected_error =
        if client == :github,
          do: :github_archive_response_too_large,
          else: :gitlab_archive_response_too_large

      assert {:error, ^expected_error} = result

      assert_receive {
        :archive_200_stream_progress,
        ^client,
        true,
        @archive_limit,
        @archive_limit,
        1
      }
    end
  end

  @tag :bounded_archive_stream
  test "bounded collector halts at the first chunk over its byte ceiling" do
    collector = ArchiveStream.into(5, @archive_stream_key)
    request = make_ref()
    response = %{status: 200, headers: %{}, body: [], private: %{}}

    assert {:cont, {^request, response}} = collector.({:data, "1234"}, {request, response})
    assert {:halt, {^request, response}} = collector.({:data, "56"}, {request, response})

    state = Map.fetch!(response.private, @archive_stream_key)
    assert state == %{bytes: 4, chunks: ["1234"], too_large?: true}
    assert IO.iodata_length(response.body) == 4
  end

  test "GitHub and GitLab archive responses stop at the byte limit for 3xx and 4xx bodies" do
    test_pid = self()
    oversized_body = :binary.copy("x", @archive_limit + 1)
    limit_bytes = @archive_limit

    for client <- [:gitlab, :github], status <- [302, 404, 503] do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, status, oversized_body) end)
      request_fun = streaming_request_fun(test_pid)

      result =
        case client do
          :gitlab ->
            GitlabClient.get_repository_archive("group", "api", "abc123",
              base_url: "https://gitlab.example.test",
              request_fun: request_fun
            )

          :github ->
            GithubClient.get_repository_archive("owner", "repo", "abc123",
              base_url: "https://api.github.example.test",
              request_fun: request_fun
            )
        end

      expected_error =
        if client == :gitlab,
          do: :gitlab_archive_response_too_large,
          else: :github_archive_response_too_large

      assert {:error, ^expected_error} = result
      assert_receive {:archive_stream_progress, ^status, retained_bytes, %{too_large?: true, bytes: stored_bytes}}
      assert retained_bytes <= @archive_limit
      assert stored_bytes <= limit_bytes
    end

    for client <- [:gitlab, :github] do
      request_fun = fn _opts ->
        {:ok, %{status: 200, headers: %{}, body: oversized_body, private: %{}}}
      end

      expected_error =
        if client == :gitlab,
          do: :gitlab_archive_response_too_large,
          else: :github_archive_response_too_large

      assert {:error, ^expected_error} =
               fetch_archive(client,
                 base_url: "https://#{origin_host(client)}",
                 token: token(client),
                 request_fun: request_fun
               )
    end
  end

  test "archive clients accept bounded binary bodies and report invalid bodies or transport errors" do
    for client <- [:github, :gitlab] do
      request_fun = fn opts ->
        assert opts[:raw] == true
        assert opts[:redirect] == false
        assert opts[:retry] == false

        {:ok, %{status: 200, headers: %{}, body: "bounded archive", private: %{}}}
      end

      assert {:ok, "bounded archive"} =
               fetch_archive(client,
                 base_url: "https://#{origin_host(client)}",
                 token: token(client),
                 request_fun: request_fun
               )

      invalid_body_request = fn _opts ->
        {:ok, %{status: 200, headers: %{}, body: :unexpected, private: %{}}}
      end

      expected_body_error =
        if client == :github,
          do: :github_archive_body_invalid,
          else: :gitlab_archive_body_invalid

      assert {:error, ^expected_body_error} =
               fetch_archive(client,
                 base_url: "https://#{origin_host(client)}",
                 token: token(client),
                 request_fun: invalid_body_request
               )

      transport_error_request = fn _opts -> {:error, :synthetic_transport_failure} end

      assert {:error, :synthetic_transport_failure} =
               fetch_archive(client,
                 base_url: "https://#{origin_host(client)}",
                 token: token(client),
                 request_fun: transport_error_request
               )
    end
  end

  test "repository snapshot adapters stop before download on branch lookup timeouts or invalid SHAs" do
    repo_ref = %{owner: "synthetic-owner", repo: "synthetic-repo"}

    branch_failures = [
      {:timeout, {:error, :timeout}},
      {:missing_sha, %{status: 200, headers: %{}, body: %{}}},
      {:invalid_sha, %{status: 200, headers: %{}, body: %{"sha" => 42}}}
    ]

    for client <- [:github, :gitlab], {failure, branch_result} <- branch_failures do
      test_pid = self()
      repo_path = repository_path(client)
      branch_path = branch_path(client)

      request_fun = fn opts ->
        url = opts[:url]

        cond do
          String.ends_with?(url, repo_path) ->
            send(test_pid, {:snapshot_lookup, :repository, url})
            {:ok, %{status: 200, headers: %{}, body: %{"default_branch" => "main"}}}

          String.contains?(url, branch_path) ->
            send(test_pid, {:snapshot_lookup, :branch, url})

            if failure == :timeout,
              do: branch_result,
              else: {:ok, branch_result}

          true ->
            flunk("repository archive download must not follow a failed branch lookup: #{url}")
        end
      end

      forge = if client == :github, do: GithubForge, else: GitlabForge
      expected_error = branch_lookup_error(client, failure)

      assert {:error, ^expected_error} =
               forge.get_repository_snapshot(
                 %{base_url: "https://#{origin_host(client)}", request_fun: request_fun},
                 repo_ref
               )

      assert_receive {:snapshot_lookup, :repository, repository_url}
      assert String.ends_with?(repository_url, repo_path)
      assert_receive {:snapshot_lookup, :branch, branch_url}
      assert String.contains?(branch_url, branch_path)
    end
  end

  test "archive redirects reject missing, malformed, or empty Location headers" do
    responses = [
      %{status: 302, headers: %{}, private: %{}},
      %{status: 302, headers: [], private: %{}},
      %{status: 302, headers: %{"location" => [nil]}, private: %{}},
      %{status: 302, headers: %{"location" => ""}, private: %{}}
    ]

    for response <- responses do
      request_fun = fn _opts -> {:ok, response} end

      assert {:error, :invalid_archive_redirect} =
               ArchiveRedirect.fetch(
                 [url: "https://archive.example.test/start"],
                 request_fun,
                 @archive_stream_key
               )
    end
  end

  test "archive redirect validation handles IP literals and rejects invalid hosts or ports" do
    valid_urls = [
      "https://127.0.0.1/archive.tar.gz",
      "https://[::1]:9443/archive.tar.gz",
      "https://storage.example.test.:443/archive.tar.gz"
    ]

    for url <- valid_urls do
      request_fun = fn _opts ->
        {:ok, %{status: 200, headers: %{}, body: "archive", private: %{}}}
      end

      assert {:ok, %{body: "archive"}} =
               ArchiveRedirect.fetch([url: url], request_fun, @archive_stream_key)
    end

    invalid_urls = [
      "https://bad..example.test/archive.tar.gz",
      "https://storage.example.test:65536/archive.tar.gz",
      "https://storage.example.test:0/archive.tar.gz",
      "https://storage.example.test:/archive.tar.gz",
      "https://storage.example.test:443.evil/archive.tar.gz"
    ]

    for url <- invalid_urls do
      request_fun = fn _opts -> flunk("invalid archive origin reached the transport: #{url}") end

      assert {:error, :invalid_archive_redirect} =
               ArchiveRedirect.fetch([url: url], request_fun, @archive_stream_key)
    end

    request_fun = fn _opts -> flunk("invalid archive origin reached the transport") end

    assert {:error, :invalid_archive_redirect} =
             ArchiveRedirect.fetch([url: nil], request_fun, @archive_stream_key)

    assert {:error, :insecure_archive_redirect} =
             ArchiveRedirect.fetch([url: "http://archive.example.test/archive.tar.gz"], request_fun, @archive_stream_key)
  end

  test "archive redirect parsing rejects malformed initial and destination URLs" do
    no_request = fn _opts -> flunk("malformed archive URLs must not reach the transport") end

    assert {:error, :invalid_archive_redirect} =
             ArchiveRedirect.fetch([url: "https://["], no_request, @archive_stream_key)

    invalid_utf8_url = "https://" <> <<255>>

    assert {:error, :invalid_archive_redirect} =
             ArchiveRedirect.fetch([url: invalid_utf8_url], no_request, @archive_stream_key)

    redirect_request = fn _opts ->
      {:ok, %{status: 302, headers: %{"location" => "https://["}, private: %{}}}
    end

    assert {:error, :invalid_archive_redirect} =
             ArchiveRedirect.fetch(
               [url: "https://archive.example.test/start"],
               redirect_request,
               @archive_stream_key
             )
  end

  test "archive redirects strip query parameters and non-Accept headers" do
    test_pid = self()

    request_fun = fn opts ->
      send(test_pid, {:redirect_request, opts})

      case opts[:url] do
        "https://archive.example.test/repository" ->
          {:ok, %{status: 302, headers: %{"location" => "/download.tar.gz"}, private: %{}}}

        "https://archive.example.test/download.tar.gz" ->
          {:ok, %{status: 200, headers: %{}, body: "archive", private: %{}}}
      end
    end

    request_opts = [
      url: "https://archive.example.test/repository",
      headers: [
        {"authorization", "SYNTHETIC-TOKEN-CANARY"},
        {"accept", "application/gzip"},
        {"x-private", "SYNTHETIC-HEADER-CANARY"},
        {:invalid_header, "ignored"}
      ],
      params: [signature: "SYNTHETIC-QUERY-CANARY"]
    ]

    assert {:ok, %{body: "archive"}} =
             ArchiveRedirect.fetch(request_opts, request_fun, @archive_stream_key)

    assert_receive {:redirect_request, initial_request}
    assert initial_request[:params] == [signature: "SYNTHETIC-QUERY-CANARY"]

    assert_receive {:redirect_request, storage_request}
    assert storage_request[:redirect] == false
    assert Keyword.has_key?(storage_request, :params) == false
    assert storage_request[:headers] == [{"accept", "application/gzip"}]
  end

  defp streaming_request_fun(test_pid) do
    fn opts ->
      into = Keyword.fetch!(opts, :into)
      assert is_function(into, 2)
      assert opts[:redirect] == false
      assert opts[:retry] == false

      wrapped_into = fn event, accumulator ->
        into.(event, accumulator) |> report_archive_progress(test_pid)
      end

      opts
      |> Keyword.put(:into, wrapped_into)
      |> Keyword.put(:plug, {Req.Test, __MODULE__})
      |> Req.request()
    end
  end

  defp report_archive_progress({action, {_request, response}} = result, test_pid)
       when action in [:cont, :halt] do
    state = Map.get(response.private, :symphony_elixir_archive_stream)
    retained_bytes = IO.iodata_length(response.body)
    send(test_pid, {:archive_stream_progress, response.status, retained_bytes, state})
    result
  end

  defp report_archive_progress(other, _test_pid), do: other

  defp run_archive_redirect(client, test_pid) do
    origin = origin_host(client)

    request_fun = fn opts ->
      send(
        test_pid,
        {:archive_request_options, URI.parse(Keyword.fetch!(opts, :url)).host, opts[:redirect], opts[:headers]}
      )

      streaming_request_fun(test_pid).(opts)
    end

    archive_opts = [
      base_url: "https://#{origin}",
      request_fun: request_fun,
      token: token(client)
    ]

    fetch_archive(client, archive_opts)
  end

  defp fetch_archive(:github, opts), do: GithubClient.get_repository_archive("owner", "repo", "sha", opts)
  defp fetch_archive(:gitlab, opts), do: GitlabClient.get_repository_archive("group", "api", "sha", opts)

  defp origin_host(:github), do: "api.github.example.com"
  defp origin_host(:gitlab), do: "gitlab.example.com"

  defp repository_path(:github), do: "/repos/synthetic-owner/synthetic-repo"
  defp repository_path(:gitlab), do: "/projects/synthetic-owner%2Fsynthetic-repo"

  defp branch_path(:github), do: "/commits/main"
  defp branch_path(:gitlab), do: "/repository/branches/main"

  defp branch_lookup_error(:github, :timeout), do: :timeout
  defp branch_lookup_error(:github, _failure), do: :github_commit_sha_missing
  defp branch_lookup_error(:gitlab, :timeout), do: :timeout
  defp branch_lookup_error(:gitlab, _failure), do: :gitlab_commit_sha_missing

  defp token(:github), do: "SYNTHETIC-GITHUB-TOKEN-CANARY"
  defp token(:gitlab), do: "SYNTHETIC-GITLAB-TOKEN-CANARY"

  defp token_header_present?(:github, headers), do: {"authorization", "Bearer #{token(:github)}"} in headers
  defp token_header_present?(:gitlab, headers), do: {"private-token", token(:gitlab)} in headers

  defp token_observed?(:github, values), do: "Bearer #{token(:github)}" in values
  defp token_observed?(:gitlab, values), do: token(:gitlab) in values

  defp assert_streamed_bytes(test_pid, status, expected_bytes) do
    assert_receive {:archive_stream_progress, ^status, retained_bytes, %{bytes: stream_bytes}}
    assert retained_bytes == stream_bytes

    if stream_bytes < expected_bytes do
      assert_streamed_bytes(test_pid, status, expected_bytes)
    else
      assert stream_bytes == expected_bytes
    end
  end
end
