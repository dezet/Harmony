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
end
