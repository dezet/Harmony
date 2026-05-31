defmodule SymphonyElixir.StorageTest do
  use SymphonyElixir.TestSupport

  test "repo module is configured for ecto" do
    assert SymphonyElixir.Repo.config()[:otp_app] == :symphony_elixir
  end

  describe "durable records" do
    setup :checkout_repo

    test "creates a project and stores work run history" do
      {:ok, project} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "portal",
          linear_project_slug: "portal-linear",
          github_owner: "dezet",
          github_repo: "portal",
          github_base_branch: "develop",
          linear_human_review_state: "Human Review",
          config_version: 1,
          config: %{"review" => %{"trigger" => "@hreview"}}
        })

      assert project.slug == "portal"

      {:ok, run} =
        SymphonyElixir.Storage.create_work_run(%{
          project_id: project.id,
          type: "implementation",
          status: "queued",
          dedupe_key: "linear:COD-5",
          linear_issue_id: "issue-1",
          linear_identifier: "COD-5",
          agent_backend: "codex",
          payload: %{"title" => "Smoke test"}
        })

      assert run.status == "queued"

      {:ok, event} =
        SymphonyElixir.Storage.append_event(%{
          project_id: project.id,
          work_run_id: run.id,
          type: "queued",
          payload: %{"source" => "linear"}
        })

      assert event.type == "queued"
    end
  end
end
