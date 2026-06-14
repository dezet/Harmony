defmodule SymphonyElixir.AddressReviewPromptTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Workflows.AddressReviewPrompt
  alias SymphonyElixir.WorkRun

  test "build/1 lists each thread and demands the structured JSON contract" do
    run = %WorkRun{
      type: "address_review",
      forge_owner: "o",
      forge_repo: "r",
      forge_pr_number: 7,
      payload: %{
        "threads" => [
          %{id: "T1", path: "lib/a.ex", line: 12, comments: [%{author: "alice", body: "rename foo"}]}
        ]
      }
    }

    prompt = AddressReviewPrompt.build(run)
    assert prompt =~ "T1"
    assert prompt =~ "lib/a.ex"
    assert prompt =~ "rename foo"
    assert prompt =~ "thread_id"
    assert prompt =~ "resolved"
  end
end
