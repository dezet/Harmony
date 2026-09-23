defmodule SymphonyElixir.Jira.CloudClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Jira.{CloudClient, Issue}

  @site_url "https://acme.atlassian.net"

  test "searches every enhanced-search token page with the required fields" do
    request_fun = fn request ->
      assert request[:method] == :post
      assert request[:url] == "#{@site_url}/rest/api/3/search/jql"
      assert request[:redirect] == false
      assert request[:json][:jql] == "project = OPS ORDER BY key ASC"
      assert request[:json][:maxResults] == 100
      assert request[:json][:fields] == ["summary", "description", "priority", "status", "created", "updated", "project"]
      assert {"accept", "application/json"} in request[:headers]
      assert {"content-type", "application/json"} in request[:headers]
      assert {"authorization", "Basic " <> Base.encode64("agent@example.org:api-token")} in request[:headers]
      assert request[:receive_timeout] == 15_000

      case request[:json][:nextPageToken] do
        nil ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "issues" => [jira_issue("101", "OPS-1", "First")],
               "nextPageToken" => "cursor-1",
               "isLast" => false
             }
           }}

        "cursor-1" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "issues" => [jira_issue("102", "OPS-2", "Second")],
               "isLast" => true
             }
           }}
      end
    end

    assert {:ok, [first, second]} =
             CloudClient.search_issues("project = OPS ORDER BY key ASC",
               site_url: @site_url,
               auth_mode: :classic,
               account_email: "agent@example.org",
               token: "api-token",
               request_fun: request_fun
             )

    assert %Issue{id: "101", key: "OPS-1", summary: "First"} = first
    assert %Issue{id: "102", key: "OPS-2", summary: "Second"} = second
    assert Issue.browse_url(first, @site_url) == "#{@site_url}/browse/OPS-1"
  end

  test "page callback runs after each enhanced-search page is normalized" do
    parent = self()

    request_fun = fn request ->
      body =
        case request[:json][:nextPageToken] do
          nil ->
            %{
              "issues" => [jira_issue("101", "OPS-1", "First")],
              "nextPageToken" => "cursor-1",
              "isLast" => false
            }

          "cursor-1" ->
            %{"issues" => [jira_issue("102", "OPS-2", "Second")], "isLast" => true}
        end

      {:ok, %Req.Response{status: 200, body: body}}
    end

    page_fun = fn [issue] ->
      send(parent, {:page, issue.id, issue.key})
      :ok
    end

    assert {:ok, [_first, _second]} =
             CloudClient.search_issues("project = OPS",
               site_url: @site_url,
               auth_mode: :classic,
               account_email: "agent@example.org",
               token: "api-token",
               request_fun: request_fun,
               page_fun: page_fun
             )

    assert_receive {:page, "101", "OPS-1"}
    assert_receive {:page, "102", "OPS-2"}
  end

  test "page callback errors stop token pagination and propagate unchanged" do
    calls = :counters.new(1, [:atomics])

    request_fun = fn _request ->
      page = :counters.get(calls, 1)
      :counters.add(calls, 1, 1)

      body =
        if page == 0 do
          %{"issues" => [jira_issue("101", "OPS-1", "First")], "nextPageToken" => "cursor-1", "isLast" => false}
        else
          %{"issues" => [jira_issue("102", "OPS-2", "Second")], "isLast" => true}
        end

      {:ok, %Req.Response{status: 200, body: body}}
    end

    assert {:error, :page_rejected} =
             CloudClient.search_issues("project = OPS",
               site_url: @site_url,
               auth_mode: :classic,
               account_email: "agent@example.org",
               token: "api-token",
               request_fun: request_fun,
               page_fun: fn [_issue] -> {:error, :page_rejected} end
             )

    assert :counters.get(calls, 1) == 1
  end

  test "rejects a repeated enhanced-search page token" do
    calls = :counters.new(1, [:atomics])

    request_fun = fn request ->
      page = :counters.get(calls, 1)
      :counters.add(calls, 1, 1)
      assert request[:json][:nextPageToken] == if(page == 0, do: nil, else: "cursor-1")

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "issues" => [jira_issue("10#{page + 1}", "OPS-#{page + 1}", "Page #{page + 1}")],
           "nextPageToken" => "cursor-1",
           "isLast" => false
         }
       }}
    end

    assert {:error, %{kind: :malformed_response}} =
             CloudClient.search_issues("project = OPS",
               site_url: @site_url,
               auth_mode: :classic,
               account_email: "agent@example.org",
               token: "api-token",
               request_fun: request_fun
             )

    assert :counters.get(calls, 1) == 2
  end

  test "maps a board to its saved filter before using enhanced JQL search" do
    request_fun = fn request ->
      assert request[:redirect] == false

      case request[:url] do
        "#{@site_url}/rest/agile/1.0/board/12/configuration" ->
          assert request[:method] == :get
          {:ok, %Req.Response{status: 200, body: %{"filter" => %{"id" => 900}}}}

        "#{@site_url}/rest/api/3/search/jql" ->
          assert request[:method] == :post

          assert request[:json][:jql] ==
                   "filter = 900 AND priority in (2, 7) AND statusCategory != Done ORDER BY key ASC"

          {:ok, %Req.Response{status: 200, body: %{"issues" => [], "isLast" => true}}}
      end
    end

    assert {:ok, []} =
             CloudClient.search_board_issues(12, ["2", "7"],
               site_url: @site_url,
               auth_mode: :classic,
               account_email: "agent@example.org",
               token: "api-token",
               request_fun: request_fun
             )
  end

  test "rejects non-numeric filter and priority IDs before making a request" do
    request_fun = fn _request -> flunk("unsafe input reached Jira") end
    opts = [site_url: @site_url, auth_mode: :classic, account_email: "a@b.test", token: "t", request_fun: request_fun]

    assert {:error, _reason} = CloudClient.search_filter_issues("1 OR project is not EMPTY", ["2"], opts)
    assert {:error, _reason} = CloudClient.search_filter_issues("1", ["2) OR project is not EMPTY"], opts)
    assert {:error, _reason} = CloudClient.search_board_issues("1 OR 1=1", ["2"], opts)
  end

  test "lists boards, filters, priorities and comments through every offset page" do
    endpoints = [
      {"/rest/agile/1.0/board", "values", %{"id" => 11, "name" => "Board"}},
      {"/rest/api/3/filter/search", "values", %{"id" => 21, "name" => "Filter"}},
      {"/rest/api/3/priority/search", "values", %{"id" => "3", "name" => "Major"}},
      {"/rest/api/3/issue/OPS-1/comment", "comments", %{"id" => "31", "body" => "Comment"}}
    ]

    Enum.each(endpoints, fn {path, collection_key, value} ->
      calls = :counters.new(1, [:atomics])

      request_fun = fn request ->
        assert request[:method] == :get
        assert request[:url] == "#{@site_url}#{path}"
        assert request[:params][:maxResults] == 100
        assert request[:redirect] == false
        assert {"authorization", "Basic " <> Base.encode64("a@b.test:t")} in request[:headers]
        offset = :counters.get(calls, 1) * 100
        assert request[:params][:startAt] == offset
        :counters.add(calls, 1, 1)

        if offset == 0 do
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"startAt" => 0, "maxResults" => 100, "total" => 101, "isLast" => false, collection_key => [value]}
           }}
        else
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"startAt" => 100, "maxResults" => 100, "total" => 101, "isLast" => true, collection_key => [Map.put(value, "id", "next")]}
           }}
        end
      end

      opts = [site_url: @site_url, auth_mode: :classic, account_email: "a@b.test", token: "t", request_fun: request_fun]

      result =
        case path do
          "/rest/agile/1.0/board" -> CloudClient.list_boards(opts)
          "/rest/api/3/filter/search" -> CloudClient.list_filters(opts)
          "/rest/api/3/priority/search" -> CloudClient.list_priorities(opts)
          "/rest/api/3/issue/OPS-1/comment" -> CloudClient.list_comments("OPS-1", opts)
        end

      assert {:ok, [^value, _second]} = result
      assert :counters.get(calls, 1) == 2
    end)
  end

  test "uses Jira's returned page-size cap to choose the next offset" do
    calls = :counters.new(1, [:atomics])

    request_fun = fn request ->
      offset = :counters.get(calls, 1) * 50
      assert request[:params][:maxResults] == 100
      assert request[:params][:startAt] == offset
      :counters.add(calls, 1, 1)

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "startAt" => offset,
           "maxResults" => 50,
           "total" => 51,
           "isLast" => offset == 50,
           "values" => [%{"id" => "#{offset + 1}"}]
         }
       }}
    end

    assert {:ok, [%{"id" => "1"}, %{"id" => "51"}]} =
             CloudClient.list_filters(
               site_url: @site_url,
               auth_mode: :classic,
               account_email: "agent@example.org",
               token: "api-token",
               request_fun: request_fun
             )
  end

  test "rejects an empty non-final offset page when Jira reports remaining results" do
    request_fun = fn _request ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"startAt" => 0, "maxResults" => 100, "total" => 2, "isLast" => false, "values" => []}
       }}
    end

    assert {:error, %{kind: :malformed_response}} =
             CloudClient.list_filters(
               site_url: @site_url,
               auth_mode: :classic,
               account_email: "agent@example.org",
               token: "api-token",
               request_fun: request_fun
             )
  end

  test "rejects incomplete enhanced-search pages and contradictory cursor state" do
    for response <- [
          %{"issues" => [], "isLast" => false},
          %{"issues" => [], "isLast" => true, "nextPageToken" => "cursor"}
        ] do
      request_fun = fn _request -> {:ok, %Req.Response{status: 200, body: response}} end

      assert {:error, %{kind: :malformed_response}} =
               CloudClient.search_issues("project = OPS",
                 site_url: @site_url,
                 auth_mode: :classic,
                 account_email: "agent@example.org",
                 token: "api-token",
                 request_fun: request_fun
               )
    end
  end

  test "accepts scoped auth only at Atlassian's fixed API host" do
    request_fun = fn request ->
      assert request[:url] == "https://api.atlassian.com/ex/jira/123e4567-e89b-12d3-a456-426614174000/rest/api/3/priority/search"
      assert {"authorization", "Bearer scoped-token"} in request[:headers]
      assert request[:redirect] == false
      {:ok, %Req.Response{status: 200, body: %{"values" => [], "isLast" => true}}}
    end

    assert {:ok, []} =
             CloudClient.list_priorities(
               auth_mode: :scoped,
               cloud_id: "123e4567-e89b-12d3-a456-426614174000",
               token: "scoped-token",
               request_fun: request_fun
             )
  end

  test "rejects unsafe site URLs and invalid scoped cloud IDs without sending credentials" do
    request_fun = fn _request -> flunk("invalid Jira URL reached the transport") end

    for site_url <- [
          "http://acme.atlassian.net",
          "https://evil.atlassian.net.example.com",
          "https://user:pass@acme.atlassian.net",
          "https://acme.atlassian.net?next=evil",
          "https://acme.atlassian.net#fragment",
          "https://acme.atlassian.net/proxy"
        ] do
      assert {:error, _reason} =
               CloudClient.list_boards(
                 site_url: site_url,
                 auth_mode: :classic,
                 account_email: "agent@example.org",
                 token: "secret",
                 request_fun: request_fun
               )
    end

    assert {:error, _reason} =
             CloudClient.list_boards(
               auth_mode: :scoped,
               cloud_id: "../../tenant",
               token: "secret",
               request_fun: request_fun
             )

    assert {:error, _reason} =
             CloudClient.list_boards(
               site_url: @site_url,
               auth_mode: :classic,
               account_email: "agent@example.org",
               token: "bad\r\nheader",
               request_fun: request_fun
             )
  end

  test "does not follow redirects or include response bodies in HTTP errors" do
    request_fun = fn request ->
      assert request[:redirect] == false
      assert {"authorization", _} = List.keyfind(request[:headers], "authorization", 0)

      {:ok,
       %Req.Response{
         status: 302,
         headers: %{"location" => ["https://evil.example/steal"]},
         body: %{"secret" => "response body"}
       }}
    end

    assert {:error, reason} =
             CloudClient.list_boards(
               site_url: @site_url,
               auth_mode: :classic,
               account_email: "agent@example.org",
               token: "api-token",
               request_fun: request_fun
             )

    refute inspect(reason) =~ "response body"
  end

  test "returns explicit sanitized status errors and preserves Retry-After" do
    Enum.each([401, 403, 404, 429, 500, 503], fn status ->
      request_fun = fn _request ->
        headers = if status == 429, do: %{"retry-after" => ["37"]}, else: %{}
        {:ok, %Req.Response{status: status, headers: headers, body: %{"secret" => "must not escape"}}}
      end

      assert {:error, error} =
               CloudClient.list_boards(
                 site_url: @site_url,
                 auth_mode: :classic,
                 account_email: "agent@example.org",
                 token: "api-token",
                 request_fun: request_fun
               )

      assert error.status == status
      assert error.retry_after == if(status == 429, do: "37", else: nil)
      refute inspect(error) =~ "must not escape"
    end)
  end

  test "normalizes timeout without exposing transport details" do
    request_fun = fn request ->
      assert request[:receive_timeout] == 1_234
      {:error, :timeout}
    end

    assert {:error, %{kind: :timeout}} =
             CloudClient.list_boards(
               site_url: @site_url,
               auth_mode: :classic,
               account_email: "agent@example.org",
               token: "api-token",
               timeout_ms: 1_234,
               request_fun: request_fun
             )
  end

  test "returns a malformed response error for successful non-page bodies" do
    for response <- [
          %Req.Response{status: 200, body: %{"notIssues" => []}},
          %{status: 200}
        ] do
      request_fun = fn _request -> {:ok, response} end

      assert {:error, %{kind: :malformed_response}} =
               CloudClient.search_issues("project = OPS",
                 site_url: @site_url,
                 auth_mode: :classic,
                 account_email: "agent@example.org",
                 token: "api-token",
                 request_fun: request_fun
               )
    end
  end

  defp jira_issue(id, key, summary) do
    %{
      "id" => id,
      "key" => key,
      "fields" => %{
        "summary" => summary,
        "description" => nil,
        "priority" => %{"id" => "2", "name" => "Major"},
        "status" => %{"id" => "3", "name" => "Open", "statusCategory" => %{"key" => "new"}},
        "created" => "2026-09-23T10:00:00.000+0000",
        "updated" => "2026-09-23T10:00:00.000+0000",
        "project" => %{"id" => "100", "key" => "OPS", "name" => "Operations"}
      }
    }
  end
end
