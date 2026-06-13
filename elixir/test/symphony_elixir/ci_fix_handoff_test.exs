defmodule SymphonyElixir.CiFixHandoffTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflows.CiFixHandoff
  alias SymphonyElixir.WorkRun

  test "comments on PR and linked Linear issue when repair is blocked" do
    parent = self()

    github_comment = fn owner, repo, pr_number, body, _opts ->
      send(parent, {:github_comment, owner, repo, pr_number, body})
      :ok
    end

    linear_comment = fn issue_id, body ->
      send(parent, {:linear_comment, issue_id, body})
      :ok
    end

    linear_state = fn issue_id, state ->
      send(parent, {:linear_state, issue_id, state})
      :ok
    end

    run = %WorkRun{
      forge_owner: "dezet",
      forge_repo: "portal",
      forge_pr_number: 7,
      linear_issue_id: "issue-1",
      linear_identifier: "COD-5",
      payload: %{blocker_reason: "fork PR requires repair branch"}
    }

    assert :ok =
             CiFixHandoff.blocked(run,
               human_review_state: "Human Review",
               github_comment: github_comment,
               linear_comment: linear_comment,
               linear_state: linear_state
             )

    assert_received {:github_comment, "dezet", "portal", 7, body}
    assert body =~ "fork PR requires repair branch"
    assert_received {:linear_comment, "issue-1", linear_body}
    assert linear_body =~ "fork PR requires repair branch"
    assert_received {:linear_state, "issue-1", "Human Review"}
  end

  test "emits work events after successful failed-ci external writes" do
    parent = self()

    append_event = fn attrs ->
      send(parent, {:work_event, attrs})
      {:ok, attrs}
    end

    run = %WorkRun{
      id: "work-run-1",
      forge_owner: "dezet",
      forge_repo: "portal",
      forge_pr_number: 7,
      linear_issue_id: "issue-1",
      payload: %{project_id: "project-1", blocker_reason: "fork PR requires repair branch"}
    }

    assert :ok =
             CiFixHandoff.blocked(run,
               human_review_state: "Human Review",
               github_comment: fn _owner, _repo, _pr_number, _body, _opts -> :ok end,
               linear_comment: fn _issue_id, _body -> :ok end,
               linear_state: fn _issue_id, _state -> :ok end,
               append_event: append_event
             )

    assert_received {:work_event, %{type: "github_comment_created", work_run_id: "work-run-1"}}
    assert_received {:work_event, %{type: "linear_comment_created", work_run_id: "work-run-1"}}
    assert_received {:work_event, %{type: "linear_state_updated", work_run_id: "work-run-1"}}
  end
end
