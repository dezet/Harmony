defmodule SymphonyElixir.WorkRunTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.WorkRun
  alias SymphonyElixir.WorkSources.LinearIssueSource

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

    run =
      WorkRun.from_linear_issue(issue,
        project_id: "storage-project-1",
        project_slug: "portal",
        base_branch: "develop",
        config_version: 4,
        required_evidence: ["browser"]
      )

    assert run.type == "implementation"
    assert run.dedupe_key == "linear:issue-1"
    assert run.linear_identifier == "COD-5"
    assert run.forge_base_ref == "develop"
    assert run.required_evidence == ["browser"]
    assert run.payload.project_id == "storage-project-1"
    assert run.payload.config_version == 4
    assert run.payload.required_evidence == ["browser"]
    assert run.payload.issue.title == "Smoke test"
  end

  test "linear issue source maps tracker issues and project metadata to work runs" do
    issue = %Issue{id: "issue-1", identifier: "COD-5", title: "Smoke", state: "Todo", project_slug: "portal"}

    fetcher = fn -> {:ok, [issue]} end

    assert {:ok, [run]} =
             LinearIssueSource.fetch_candidates(
               issue_fetcher: fetcher,
               project_id: "storage-project-1",
               project_slug: "portal",
               base_branch: "develop",
               config_version: 4,
               required_evidence: ["browser"]
             )

    assert run.type == "implementation"
    assert run.linear_identifier == "COD-5"
    assert run.payload.project_id == "storage-project-1"
    assert run.payload.config_version == 4
    assert run.required_evidence == ["browser"]
  end
end
