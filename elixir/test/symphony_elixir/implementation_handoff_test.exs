defmodule SymphonyElixir.ImplementationHandoffTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RuntimePolicy.ImplementationHandoff
  alias SymphonyElixir.WorkRun

  test "moves linked Linear issue to Human Review when a valid PR link exists" do
    parent = self()

    run = %WorkRun{
      id: "work-run-1",
      type: "implementation",
      forge_base_ref: "develop",
      linear_issue_id: "issue-1",
      linear_identifier: "COD-5",
      payload: %{project_id: "project-1"}
    }

    project = %{
      id: "project-1",
      linear_human_review_state: "Human Review",
      forge_base_branch: "develop"
    }

    pr_link = %{
      forge_pr_number: 7,
      forge_head_ref: "feature/cod-5",
      forge_base_ref: "develop",
      linear_issue_id: "issue-1",
      linear_identifier: "COD-5"
    }

    assert :ok =
             ImplementationHandoff.publish(run,
               get_project: fn "project-1" -> project end,
               find_pull_request_link: fn "project-1", "issue-1", "COD-5" -> pr_link end,
               tracker_update: fn issue_id, state ->
                 send(parent, {:linear_state, issue_id, state})
                 :ok
               end,
               append_event: fn attrs ->
                 send(parent, {:work_event, attrs})
                 {:ok, attrs}
               end
             )

    assert_received {:linear_state, "issue-1", "Human Review"}
    assert_received {:work_event, %{type: "linear_state_updated", work_run_id: "work-run-1"}}
  end

  test "blocks and comments when implementation completes without a linked PR" do
    parent = self()

    run = %WorkRun{
      id: "work-run-1",
      type: "implementation",
      linear_issue_id: "issue-1",
      linear_identifier: "COD-5",
      payload: %{project_id: "project-1"}
    }

    assert {:error, :missing_pull_request_link} =
             ImplementationHandoff.publish(run,
               get_project: fn "project-1" -> %{id: "project-1", forge_base_branch: "develop"} end,
               find_pull_request_link: fn "project-1", "issue-1", "COD-5" -> nil end,
               linear_comment: fn issue_id, body ->
                 send(parent, {:linear_comment, issue_id, body})
                 :ok
               end,
               record_blocker: fn attrs ->
                 send(parent, {:blocker, attrs})
                 {:ok, attrs}
               end
             )

    assert_received {:linear_comment, "issue-1", body}
    assert body =~ "could not find a linked pull request"

    assert_received {:blocker,
                     %{
                       project_id: "project-1",
                       work_run_id: "work-run-1",
                       target_type: "linear_issue",
                       target_id: "issue-1",
                       reason: "missing_pull_request_link"
                     }}
  end

  test "blocks when linked PR base branch is not the project base branch" do
    parent = self()

    run = %WorkRun{
      id: "work-run-1",
      type: "implementation",
      forge_base_ref: "develop",
      linear_issue_id: "issue-1",
      linear_identifier: "COD-5",
      payload: %{project_id: "project-1"}
    }

    pr_link = %{
      forge_pr_number: 7,
      forge_head_ref: "feature/cod-5",
      forge_base_ref: "main",
      linear_issue_id: "issue-1",
      linear_identifier: "COD-5"
    }

    assert {:error, {:invalid_pull_request_link, :base_branch_mismatch}} =
             ImplementationHandoff.publish(run,
               get_project: fn "project-1" -> %{id: "project-1", forge_base_branch: "develop"} end,
               find_pull_request_link: fn "project-1", "issue-1", "COD-5" -> pr_link end,
               record_blocker: fn attrs ->
                 send(parent, {:blocker, attrs})
                 {:ok, attrs}
               end
             )

    assert_received {:blocker, %{reason: "invalid_pull_request_link:base_branch_mismatch"}}
  end
end
