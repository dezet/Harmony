defmodule SymphonyElixir.RuntimePolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RuntimePolicy.RepoPolicy

  test "rejects push to base branch" do
    assert {:error, :base_branch_push_forbidden} =
             RepoPolicy.authorize_push(%{
               head_repo_full_name: "dezet/portal",
               base_repo_full_name: "dezet/portal",
               head_ref: "develop",
               base_ref: "develop",
               protected_branches: ["develop"]
             })
  end

  test "allows same repo feature branch push" do
    assert :ok =
             RepoPolicy.authorize_push(%{
               head_repo_full_name: "dezet/portal",
               base_repo_full_name: "dezet/portal",
               head_ref: "harmony-smoke-test-cod-5",
               base_ref: "develop",
               protected_branches: ["develop"]
             })
  end

  test "routes forks to repair branch flow" do
    assert {:error, :fork_pr_requires_repair_branch} =
             RepoPolicy.authorize_push(%{
               head_repo_full_name: "contrib/portal",
               base_repo_full_name: "dezet/portal",
               head_ref: "fix-ci",
               base_ref: "develop",
               protected_branches: ["develop"]
             })
  end
end
