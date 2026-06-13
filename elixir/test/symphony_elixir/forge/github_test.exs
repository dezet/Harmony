defmodule SymphonyElixir.Forge.GithubTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Forge.Github

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
end
