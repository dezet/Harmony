defmodule SymphonyElixir.GithubLinkResolverTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Github.LinkResolver
  alias SymphonyElixir.Github.PullRequest

  test "finds linear URL and issue identifier in PR body and branch" do
    pr = %PullRequest{
      number: 1,
      body: "Linear: https://linear.app/dezet/issue/COD-5/smoke-test",
      head_ref: "harmony-smoke-test-cod-5",
      title: "Smoke"
    }

    assert %{identifier: "COD-5", url: "https://linear.app/dezet/issue/COD-5/smoke-test"} =
             LinkResolver.resolve(pr, team_keys: ["COD"])
  end

  test "returns nil when no configured team key is present" do
    pr = %PullRequest{number: 2, body: "No issue", head_ref: "feature/no-issue", title: "No issue"}
    assert is_nil(LinkResolver.resolve(pr, team_keys: ["COD"]))
  end
end
