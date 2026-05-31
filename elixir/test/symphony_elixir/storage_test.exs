defmodule SymphonyElixir.StorageTest do
  use SymphonyElixir.TestSupport

  test "repo module is configured for ecto" do
    assert SymphonyElixir.Repo.config()[:otp_app] == :symphony_elixir
  end

  describe "durable records" do
    @tag :db
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

    @tag :db
    test "tracks dedupe statuses and treats blocked as seen" do
      {:ok, project} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "portal-dedupe",
          linear_project_slug: "portal-linear",
          github_owner: "dezet",
          github_repo: "portal",
          github_base_branch: "develop",
          linear_human_review_state: "Human Review",
          config_version: 1,
          config: %{}
        })

      refute SymphonyElixir.Storage.dedupe_seen?(project.id, "github-ci-fix:1")

      assert {:ok, _record} =
               SymphonyElixir.Storage.mark_dedupe_blocked(%{
                 project_id: project.id,
                 key: "github-ci-fix:1",
                 scope: "ci_fix",
                 metadata: %{"reason" => "unsafe"}
               })

      assert SymphonyElixir.Storage.dedupe_seen?(project.id, "github-ci-fix:1")
      assert "blocked" == SymphonyElixir.Storage.dedupe_status(project.id, "github-ci-fix:1")
    end

    @tag :db
    test "detects open blockers for dispatch targets" do
      {:ok, project} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "portal-blockers",
          linear_project_slug: "portal-linear",
          github_owner: "dezet",
          github_repo: "portal",
          github_base_branch: "develop",
          linear_human_review_state: "Human Review",
          config_version: 1,
          config: %{}
        })

      refute SymphonyElixir.Storage.open_blocker_exists?(project.id, "linear_issue", "issue-1")

      assert {:ok, _blocker} =
               SymphonyElixir.Storage.upsert_open_blocker(%{
                 project_id: project.id,
                 target_type: "linear_issue",
                 target_id: "issue-1",
                 reason: "missing PR",
                 metadata: %{}
               })

      assert SymphonyElixir.Storage.open_blocker_exists?(project.id, "linear_issue", "issue-1")
    end
  end
end
