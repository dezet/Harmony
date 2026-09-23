defmodule SymphonyElixir.Forge.GithubTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Forge.Github
  alias SymphonyElixir.Github.Comment

  test "list_change_requests normalizes GitHub PRs and uses base_url" do
    fake = fn opts ->
      assert opts[:url] =~ "https://ghe.example.com/repos/o/r/pulls"
      {:ok, %{status: 200, body: [%{"number" => 7, "head" => %{"sha" => "abc", "ref" => "f"}, "base" => %{"ref" => "main"}, "html_url" => "u"}]}}
    end

    creds = %{token: "t", base_url: "https://ghe.example.com", request_fun: fake}
    ref = %{owner: "o", repo: "r", base_url: "https://ghe.example.com"}
    assert {:ok, [%{number: 7, head_sha: "abc"}]} = Github.list_change_requests(creds, ref, [])
  end

  test "list_repositories hits /user/repos by default and normalizes" do
    fake = fn opts ->
      assert opts[:url] =~ "/user/repos"
      {:ok, %{status: 200, body: [%{"name" => "r", "owner" => %{"login" => "o"}, "default_branch" => "main", "html_url" => "u"}]}}
    end

    assert {:ok, [%{owner: "o", name: "r", default_branch: "main"}]} =
             Github.list_repositories(%{token: "t", request_fun: fake}, [])
  end

  test "get_repository returns default_branch" do
    fake = fn opts ->
      assert opts[:url] =~ "/repos/o/r"
      {:ok, %{status: 200, body: %{"name" => "r", "owner" => %{"login" => "o"}, "default_branch" => "develop", "html_url" => "u"}}}
    end

    assert {:ok, %{default_branch: "develop"}} = Github.get_repository(%{token: "t", request_fun: fake}, "o", "r")
  end

  test "get_repository_snapshot reads the default-branch SHA and archive at that SHA" do
    archive = <<31, 139, 8, 0, 0>>

    fake = fn opts ->
      assert {"authorization", "Bearer synthetic-token"} in opts[:headers]

      cond do
        opts[:url] == "https://ghe.example.com/repos/o/r" ->
          {:ok, %{status: 200, body: %{"default_branch" => "main"}}}

        opts[:url] == "https://ghe.example.com/repos/o/r/commits/main" ->
          {:ok, %{status: 200, body: %{"sha" => "abc123"}}}

        opts[:url] == "https://ghe.example.com/repos/o/r/tarball/abc123" ->
          assert opts[:redirect] == false
          {:ok, %{status: 200, body: archive}}

        true ->
          flunk("unexpected GitHub snapshot URL: #{opts[:url]}")
      end
    end

    ref = %{owner: "o", repo: "r", base_url: "https://ghe.example.com"}

    assert {:ok, %{default_branch: "main", sha: "abc123", archive: ^archive}} =
             Github.get_repository_snapshot(
               %{token: "synthetic-token", base_url: "https://ghe.example.com", request_fun: fake},
               ref
             )
  end

  test "list_change_request_comments normalizes GitHub issue comments and honors base_url" do
    fake = fn opts ->
      assert opts[:method] == :get
      assert opts[:url] =~ "https://ghe.example.com/repos/o/r/issues/7/comments"
      {:ok, %{status: 200, body: [%{"id" => 11, "body" => "@hreview please", "user" => %{"login" => "octo"}}]}}
    end

    creds = %{token: "t", base_url: "https://ghe.example.com", request_fun: fake}
    ref = %{owner: "o", repo: "r", base_url: "https://ghe.example.com"}

    assert {:ok, [%Comment{id: 11, body: "@hreview please", author: "octo"}]} =
             Github.list_change_request_comments(creds, ref, 7)
  end
end
