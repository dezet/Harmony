defmodule SymphonyElixir.GithubClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Github.Client

  test "lists open pull requests with normalized fields" do
    request_fun = fn opts ->
      send(self(), {:github_request, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: [
           %{
             "number" => 7,
             "title" => "Fix CI",
             "html_url" => "https://github.com/dezet/portal/pull/7",
             "head" => %{
               "sha" => "abc123",
               "ref" => "fix-ci",
               "repo" => %{"full_name" => "dezet/portal"}
             },
             "base" => %{
               "ref" => "develop",
               "repo" => %{"full_name" => "dezet/portal"}
             },
             "body" => "Linear: COD-5"
           }
         ]
       }}
    end

    assert {:ok, [pr]} =
             Client.list_open_pull_requests("dezet", "portal",
               token: "token",
               request_fun: request_fun
             )

    assert pr.number == 7
    assert pr.head_sha == "abc123"
    assert pr.head_repo_full_name == "dezet/portal"
    assert pr.base_ref == "develop"

    assert_received {:github_request, opts}
    assert opts[:method] == :get
    assert opts[:url] =~ "/repos/dezet/portal/pulls"
    assert {"authorization", "Bearer token"} in opts[:headers]
  end

  test "lists PR comments" do
    request_fun = fn opts ->
      assert opts[:url] =~ "/repos/dezet/portal/issues/7/comments"

      {:ok,
       %Req.Response{
         status: 200,
         body: [%{"id" => 99, "body" => "@hreview please", "user" => %{"login" => "alice"}}]
       }}
    end

    assert {:ok, [comment]} =
             Client.list_issue_comments("dezet", "portal", 7,
               token: "token",
               request_fun: request_fun
             )

    assert comment.id == 99
    assert comment.body == "@hreview please"
  end

  test "lists workflow runs for a head sha" do
    request_fun = fn opts ->
      assert opts[:url] =~ "/repos/dezet/portal/actions/runs"
      assert opts[:params][:head_sha] == "abc123"

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "workflow_runs" => [
             %{
               "id" => 123,
               "name" => "CI",
               "head_sha" => "abc123",
               "status" => "completed",
               "conclusion" => "failure",
               "html_url" => "https://github.com/dezet/portal/actions/runs/123"
             }
           ]
         }
       }}
    end

    assert {:ok, [run]} =
             Client.list_workflow_runs("dezet", "portal",
               head_sha: "abc123",
               token: "token",
               request_fun: request_fun
             )

    assert run.id == 123
    assert run.conclusion == "failure"
  end
end
