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

  describe "list_work_runs_for_project/2" do
    @tag :db
    setup :checkout_repo

    setup do
      {:ok, project} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "paginate-proj",
          linear_project_slug: "paginate-linear",
          github_owner: "acme",
          github_repo: "widget",
          github_base_branch: "main",
          linear_human_review_state: "Human Review",
          config_version: 1,
          config: %{}
        })

      {:ok, other_project} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "other-proj",
          linear_project_slug: "other-linear",
          github_owner: "acme",
          github_repo: "other",
          github_base_branch: "main",
          linear_human_review_state: "Human Review",
          config_version: 1,
          config: %{}
        })

      %{project: project, other_project: other_project}
    end

    defp insert_work_run(project_id, attrs) do
      defaults = %{
        project_id: project_id,
        type: "implementation",
        status: "queued",
        agent_backend: "codex",
        payload: %{}
      }

      {:ok, run} = SymphonyElixir.Storage.create_work_run(Map.merge(defaults, attrs))
      run
    end

    defp set_inserted_at(run, inserted_at) do
      import Ecto.Query
      SymphonyElixir.Repo.update_all(
        from(r in SymphonyElixir.Storage.WorkRun, where: r.id == ^run.id),
        set: [inserted_at: inserted_at]
      )
      %{run | inserted_at: inserted_at}
    end

    @tag :db
    test "returns work runs for a project ordered newest-first", %{project: project, other_project: other_project} do
      run1 = insert_work_run(project.id, %{linear_identifier: "COD-1"}) |> set_inserted_at(~U[2026-06-13 10:00:01.000000Z])
      run2 = insert_work_run(project.id, %{linear_identifier: "COD-2"}) |> set_inserted_at(~U[2026-06-13 10:00:02.000000Z])
      run3 = insert_work_run(project.id, %{linear_identifier: "COD-3"}) |> set_inserted_at(~U[2026-06-13 10:00:03.000000Z])
      _other_run = insert_work_run(other_project.id, %{linear_identifier: "OTH-1"})

      runs = SymphonyElixir.Storage.list_work_runs_for_project(project.id)

      ids = Enum.map(runs, & &1.id)
      assert ids == [run3.id, run2.id, run1.id]
      refute Enum.any?(runs, &(&1.id == other_project.id))
    end

    @tag :db
    test "filters by status when opts[:status] is provided", %{project: project} do
      insert_work_run(project.id, %{status: "queued"})
      run2 = insert_work_run(project.id, %{status: "running"})
      run3 = insert_work_run(project.id, %{status: "running"})

      running = SymphonyElixir.Storage.list_work_runs_for_project(project.id, %{status: "running"})

      ids = Enum.map(running, & &1.id)
      assert run3.id in ids
      assert run2.id in ids
      refute Enum.any?(running, &(&1.status != "running"))
    end

    @tag :db
    test "overfetches page_size + 1 rows so caller can detect next page", %{project: project} do
      for i <- 1..3 do
        insert_work_run(project.id, %{linear_identifier: "COD-#{i}"})
      end

      rows = SymphonyElixir.Storage.list_work_runs_for_project(project.id, %{page_size: 2})
      assert length(rows) == 3
    end

    @tag :db
    test "cursor pagination returns correct second page without overlap", %{project: project} do
      run1 = insert_work_run(project.id, %{linear_identifier: "COD-1"}) |> set_inserted_at(~U[2026-06-13 11:00:01.000000Z])
      run2 = insert_work_run(project.id, %{linear_identifier: "COD-2"}) |> set_inserted_at(~U[2026-06-13 11:00:02.000000Z])
      run3 = insert_work_run(project.id, %{linear_identifier: "COD-3"}) |> set_inserted_at(~U[2026-06-13 11:00:03.000000Z])

      # First page of 2 (overfetch gives 3 rows) → take the 2nd row as cursor pivot
      page1 = SymphonyElixir.Storage.list_work_runs_for_project(project.id, %{page_size: 2})
      assert length(page1) == 3

      # The 2nd row of page1 is the last visible row (index 1)
      pivot = Enum.at(page1, 1)
      cursor = SymphonyElixir.Storage.encode_work_run_cursor(pivot)

      page2 = SymphonyElixir.Storage.list_work_runs_for_project(project.id, %{page_size: 2, cursor: cursor})

      page2_ids = Enum.map(page2, & &1.id)
      assert run1.id in page2_ids
      refute run2.id in page2_ids
      refute run3.id in page2_ids
    end

    @tag :db
    test "invalid cursor string behaves like no cursor (returns first page)", %{project: project} do
      for i <- 1..3 do
        insert_work_run(project.id, %{linear_identifier: "COD-#{i}"})
      end

      runs_no_cursor = SymphonyElixir.Storage.list_work_runs_for_project(project.id, %{page_size: 10})
      runs_bad_cursor = SymphonyElixir.Storage.list_work_runs_for_project(project.id, %{page_size: 10, cursor: "not-valid-base64url!!"})

      assert Enum.map(runs_no_cursor, & &1.id) == Enum.map(runs_bad_cursor, & &1.id)
    end
  end

  describe "encode_work_run_cursor/1 and decode_work_run_cursor/1" do
    test "encode/decode round-trip" do
      fake_run = %SymphonyElixir.Storage.WorkRun{
        id: "550e8400-e29b-41d4-a716-446655440000",
        inserted_at: ~U[2024-01-15 10:30:00.123456Z]
      }

      cursor = SymphonyElixir.Storage.encode_work_run_cursor(fake_run)
      assert is_binary(cursor)
      refute String.ends_with?(cursor, "=")

      assert {:ok, decoded} = SymphonyElixir.Storage.decode_work_run_cursor(cursor)
      assert decoded.id == fake_run.id
      assert decoded.inserted_at == fake_run.inserted_at
    end

    test "decode returns :error for garbage input" do
      assert :error == SymphonyElixir.Storage.decode_work_run_cursor("totally-not-valid")
      assert :error == SymphonyElixir.Storage.decode_work_run_cursor("")
      assert :error == SymphonyElixir.Storage.decode_work_run_cursor("e30=")
    end

    test "decode returns :error for valid base64url but invalid JSON structure" do
      bad = Base.url_encode64(~s({"foo":"bar"}), padding: false)
      assert :error == SymphonyElixir.Storage.decode_work_run_cursor(bad)
    end
  end

  describe "list_pull_request_links_for_project/1" do
    @tag :db
    setup :checkout_repo

    @tag :db
    test "returns PR links for a project ordered by updated_at desc" do
      {:ok, project} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "pr-link-proj",
          linear_project_slug: "pr-linear",
          github_owner: "acme",
          github_repo: "widget",
          github_base_branch: "main",
          linear_human_review_state: "Human Review",
          config_version: 1,
          config: %{}
        })

      {:ok, pr1} =
        SymphonyElixir.Storage.upsert_pull_request_link(%{
          project_id: project.id,
          github_owner: "acme",
          github_repo: "widget",
          github_pr_number: 10,
          metadata: %{}
        })

      {:ok, pr2} =
        SymphonyElixir.Storage.upsert_pull_request_link(%{
          project_id: project.id,
          github_owner: "acme",
          github_repo: "widget",
          github_pr_number: 20,
          metadata: %{}
        })

      {:ok, pr3} =
        SymphonyElixir.Storage.upsert_pull_request_link(%{
          project_id: project.id,
          github_owner: "acme",
          github_repo: "widget",
          github_pr_number: 30,
          metadata: %{}
        })

      # Stamp distinct updated_at values so the ordering assertion is unambiguous
      import Ecto.Query
      t1 = ~U[2026-06-13 12:00:01.000000Z]
      t2 = ~U[2026-06-13 12:00:02.000000Z]
      t3 = ~U[2026-06-13 12:00:03.000000Z]
      SymphonyElixir.Repo.update_all(from(l in SymphonyElixir.Storage.PullRequestLink, where: l.id == ^pr1.id), set: [updated_at: t1])
      SymphonyElixir.Repo.update_all(from(l in SymphonyElixir.Storage.PullRequestLink, where: l.id == ^pr2.id), set: [updated_at: t2])
      SymphonyElixir.Repo.update_all(from(l in SymphonyElixir.Storage.PullRequestLink, where: l.id == ^pr3.id), set: [updated_at: t3])

      links = SymphonyElixir.Storage.list_pull_request_links_for_project(project.id)
      ids = Enum.map(links, & &1.id)

      # All three are returned
      assert pr1.id in ids
      assert pr2.id in ids
      assert pr3.id in ids

      # Ordered strictly by updated_at desc (most recently updated first)
      updated_ats = Enum.map(links, & &1.updated_at)
      assert updated_ats == Enum.sort_by(updated_ats, & &1, {:desc, DateTime})
      [first, second | _] = links
      assert DateTime.compare(first.updated_at, second.updated_at) == :gt
    end

    @tag :db
    test "does not return PR links for other projects" do
      {:ok, project_a} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "pr-proj-a",
          linear_project_slug: "a-linear",
          github_owner: "acme",
          github_repo: "alpha",
          github_base_branch: "main",
          linear_human_review_state: "Human Review",
          config_version: 1,
          config: %{}
        })

      {:ok, project_b} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "pr-proj-b",
          linear_project_slug: "b-linear",
          github_owner: "acme",
          github_repo: "beta",
          github_base_branch: "main",
          linear_human_review_state: "Human Review",
          config_version: 1,
          config: %{}
        })

      {:ok, _pra} =
        SymphonyElixir.Storage.upsert_pull_request_link(%{
          project_id: project_a.id,
          github_owner: "acme",
          github_repo: "alpha",
          github_pr_number: 1,
          metadata: %{}
        })

      {:ok, prb} =
        SymphonyElixir.Storage.upsert_pull_request_link(%{
          project_id: project_b.id,
          github_owner: "acme",
          github_repo: "beta",
          github_pr_number: 1,
          metadata: %{}
        })

      links = SymphonyElixir.Storage.list_pull_request_links_for_project(project_a.id)
      ids = Enum.map(links, & &1.id)
      assert length(ids) == 1
      refute prb.id in ids
    end
  end
end
