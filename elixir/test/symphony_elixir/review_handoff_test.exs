defmodule SymphonyElixir.ReviewHandoffTest do
  use SymphonyElixir.TestSupport

  test "posts formal comment review with processed marker" do
    parent = self()

    create_review = fn owner, repo, pr_number, body, opts ->
      send(parent, {:review, owner, repo, pr_number, body, opts})
      :ok
    end

    run = %SymphonyElixir.WorkRun{
      dedupe_key: "github-review:dezet/portal:7:99:abc123:1",
      github_owner: "dezet",
      github_repo: "portal",
      github_pr_number: 7
    }

    assert :ok =
             SymphonyElixir.Workflows.ReviewHandoff.publish(run, "Review body", create_review: create_review)

    assert_received {:review, "dezet", "portal", 7, body, opts}
    assert body =~ "Review body"
    assert body =~ "harmony-review-processed"
    assert opts[:event] == "COMMENT"
  end
end
