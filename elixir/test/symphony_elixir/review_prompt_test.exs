defmodule SymphonyElixir.ReviewPromptTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflows.ReviewPrompt
  alias SymphonyElixir.WorkRun

  test "builds aggregate review prompt" do
    run = %WorkRun{
      type: "code_review",
      forge_owner: "dezet",
      forge_repo: "portal",
      forge_pr_number: 7,
      forge_head_sha: "abc123",
      payload: %{
        trigger_comment_id: 99,
        template: "Review correctness, tests, and maintainability."
      }
    }

    prompt = ReviewPrompt.build(run)

    assert prompt =~ "Perform a comprehensive code review"
    assert prompt =~ "Review correctness, tests, and maintainability."
    assert prompt =~ "Do not request changes automatically"
  end
end
