defmodule SymphonyElixir.RuntimePolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RuntimePolicy.{Blocker, Handoff, RepoPolicy}
  alias SymphonyElixir.Storage

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

  test "handoff moves linked linear issue to configured human review state" do
    parent = self()

    tracker = fn issue_id, state_name ->
      send(parent, {:state_update, issue_id, state_name})
      :ok
    end

    assert :ok =
             Handoff.move_to_human_review(
               %{linear_issue_id: "issue-1"},
               "Human Review",
               tracker_update: tracker
             )

    assert_received {:state_update, "issue-1", "Human Review"}
  end

  @tag :db
  test "records blocker and suppresses duplicate open blocker" do
    :ok = checkout_repo(%{})

    {:ok, project} =
      Storage.upsert_project(%{
        slug: "portal",
        forge_owner: "dezet",
        forge_repo: "portal",
        forge_base_branch: "develop",
        linear_project_slug: "portal-linear",
        linear_human_review_state: "Human Review",
        config_version: 1,
        config: %{}
      })

    attrs = %{
      project_id: project.id,
      target_type: "linear_issue",
      target_id: "issue-1",
      reason: "missing acceptance criteria",
      metadata: %{"identifier" => "COD-5"}
    }

    assert {:ok, first} = Blocker.record(attrs)
    assert {:ok, second} = Blocker.record(attrs)
    assert first.id == second.id
  end
end
