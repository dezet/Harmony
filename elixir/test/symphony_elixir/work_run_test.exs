defmodule SymphonyElixir.WorkRunTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.WorkRun

  test "builds implementation work run from linear issue" do
    issue = %Issue{
      id: "issue-1",
      identifier: "COD-5",
      title: "Smoke test",
      description: "Create a proof of life",
      state: "Todo",
      url: "https://linear.app/dezet/issue/COD-5/smoke-test",
      project_id: "project-1",
      project_name: "Portal",
      project_slug: "portal"
    }

    run = WorkRun.from_linear_issue(issue, project_slug: "portal", base_branch: "develop")

    assert run.type == "implementation"
    assert run.dedupe_key == "linear:issue-1"
    assert run.linear_identifier == "COD-5"
    assert run.github_base_ref == "develop"
    assert run.payload.issue.title == "Smoke test"
  end
end
