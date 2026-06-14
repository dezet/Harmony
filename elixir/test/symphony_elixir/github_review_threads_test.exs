defmodule SymphonyElixir.GithubReviewThreadsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Forge.Github

  @list_body %{
    "data" => %{
      "repository" => %{
        "pullRequest" => %{
          "reviewThreads" => %{
            "nodes" => [
              %{
                "id" => "T1",
                "isResolved" => false,
                "path" => "lib/a.ex",
                "line" => 12,
                "comments" => %{
                  "nodes" => [
                    %{"id" => "C1", "author" => %{"login" => "alice"}, "body" => "rename", "createdAt" => "2026-06-14T10:00:00Z"}
                  ]
                }
              }
            ]
          }
        }
      }
    }
  }

  test "list_review_threads normalizes GraphQL nodes" do
    request_fun = fn _req -> {:ok, %Req.Response{status: 200, body: @list_body}} end
    creds = %{token: "t", base_url: nil, request_fun: request_fun}

    assert {:ok, [thread]} = Github.list_review_threads(creds, %{owner: "o", repo: "r"}, 7)
    assert thread.id == "T1"
    assert thread.resolved == false
    assert thread.path == "lib/a.ex"
    assert thread.author == "alice"
    assert [%{id: "C1", author: "alice", body: "rename"}] = thread.comments
  end

  test "resolve_review_thread issues the resolve mutation with the thread id" do
    test_pid = self()

    request_fun = fn req ->
      send(test_pid, {:body, req.body})
      {:ok, %Req.Response{status: 200, body: %{"data" => %{"resolveReviewThread" => %{"thread" => %{"id" => "T1"}}}}}}
    end

    creds = %{token: "t", base_url: nil, request_fun: request_fun}
    assert :ok = Github.resolve_review_thread(creds, %{owner: "o", repo: "r"}, 7, "T1")
    assert_received {:body, body}
    assert body =~ "T1"
  end
end
