defmodule SymphonyElixir.ReviewHandoffTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflows.ReviewHandoff
  alias SymphonyElixir.WorkRun

  test "posts formal comment review with processed marker" do
    parent = self()

    create_review = fn owner, repo, pr_number, body, opts ->
      send(parent, {:review, owner, repo, pr_number, body, opts})
      :ok
    end

    run = %WorkRun{
      dedupe_key: "github-review:dezet/portal:7:99:abc123:1",
      github_owner: "dezet",
      github_repo: "portal",
      github_pr_number: 7
    }

    assert :ok =
             ReviewHandoff.publish(run, "Review body", create_review: create_review)

    assert_received {:review, "dezet", "portal", 7, body, opts}
    assert body =~ "Review body"
    assert body =~ "harmony-review-processed"
    assert opts[:event] == "COMMENT"
  end

  test "marks review trigger dedupe after successful publish" do
    parent = self()

    create_review = fn _owner, _repo, _pr_number, _body, _opts ->
      send(parent, :review_created)
      :ok
    end

    mark_dedupe_processed = fn attrs ->
      send(parent, {:dedupe_marked, attrs})
      {:ok, attrs}
    end

    run = %WorkRun{
      dedupe_key: "github-review:dezet/portal:7:99:abc123:1",
      github_owner: "dezet",
      github_repo: "portal",
      github_pr_number: 7,
      payload: %{project_id: "project-1"}
    }

    assert :ok =
             ReviewHandoff.publish(run, "Review body",
               create_review: create_review,
               mark_dedupe_processed: mark_dedupe_processed
             )

    assert_received :review_created

    assert_received {:dedupe_marked,
                     %{
                       project_id: "project-1",
                       key: "github-review:dezet/portal:7:99:abc123:1",
                       scope: "github_review",
                       status: "processed",
                       metadata: %{"github_pr_number" => 7}
                     }}
  end
end
