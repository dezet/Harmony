defmodule SymphonyElixir.CiFixHandoffTest do
  use SymphonyElixir.TestSupport

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

    run = %SymphonyElixir.WorkRun{
      github_owner: "dezet",
      github_repo: "portal",
      github_pr_number: 7,
      linear_issue_id: "issue-1",
      linear_identifier: "COD-5",
      payload: %{blocker_reason: "fork PR requires repair branch"}
    }

    assert :ok =
             SymphonyElixir.Workflows.CiFixHandoff.blocked(run,
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
end
