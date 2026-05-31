defmodule SymphonyElixir.CiFixPromptTest do
  use SymphonyElixir.TestSupport

  test "builds prompt with PR and failing workflow context" do
    run = %SymphonyElixir.WorkRun{
      type: "ci_fix",
      github_owner: "dezet",
      github_repo: "portal",
      github_pr_number: 7,
      github_head_sha: "abc123",
      github_head_ref: "fix-cod-5",
      github_base_ref: "develop",
      payload: %{
        workflow_run: %{id: 123, name: "CI", url: "https://github.com/dezet/portal/actions/runs/123"},
        log_excerpt: "cargo test failed"
      }
    }

    prompt = SymphonyElixir.Workflows.CiFixPrompt.build(run)

    assert prompt =~ "Fix the failed GitHub Actions run"
    assert prompt =~ "PR #7"
    assert prompt =~ "cargo test failed"
    assert prompt =~ "Do not merge the pull request"
  end
end
