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

  describe "forge_* fields on Project" do
    @tag :db
    setup :checkout_repo

    @tag :db
    test "project persists forge_* fields and defaults forge_type to github" do
      {:ok, project} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "forge-fields",
          github_owner: "o",
          github_repo: "r",
          github_base_branch: "main",
          forge_owner: "o",
          forge_repo: "r",
          forge_base_branch: "main",
          forge_base_url: "https://ghe.example.com",
          config_version: 1,
          config: %{}
        })

      assert project.forge_owner == "o"
      assert project.forge_repo == "r"
      assert project.forge_base_branch == "main"
      assert project.forge_base_url == "https://ghe.example.com"
      assert project.forge_type == "github"
    end

    @tag :db
    test "forge_type defaults to github when omitted" do
      {:ok, project} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "forge-default-type",
          github_owner: "o",
          github_repo: "r",
          github_base_branch: "main",
          config_version: 1,
          config: %{}
        })

      assert project.forge_type == "github"
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

  describe "get_work_run_by_linear_identifier/1" do
    @tag :db
    setup :checkout_repo

    setup do
      {:ok, project} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "ident-proj",
          linear_project_slug: "ident-linear",
          github_owner: "acme",
          github_repo: "widget",
          github_base_branch: "main",
          linear_human_review_state: "Human Review",
          config_version: 1,
          config: %{}
        })

      %{project: project}
    end

    defp insert_run_with_identifier(project_id, identifier) do
      defaults = %{
        project_id: project_id,
        type: "implementation",
        status: "queued",
        agent_backend: "codex",
        payload: %{}
      }

      {:ok, run} = SymphonyElixir.Storage.create_work_run(Map.merge(defaults, %{linear_identifier: identifier}))
      run
    end

    defp set_run_inserted_at(run, inserted_at) do
      import Ecto.Query

      SymphonyElixir.Repo.update_all(
        from(r in SymphonyElixir.Storage.WorkRun, where: r.id == ^run.id),
        set: [inserted_at: inserted_at]
      )

      %{run | inserted_at: inserted_at}
    end

    @tag :db
    test "returns the most recent run matching the identifier", %{project: project} do
      older = insert_run_with_identifier(project.id, "COD-42") |> set_run_inserted_at(~U[2026-06-13 09:00:00.000000Z])
      newer = insert_run_with_identifier(project.id, "COD-42") |> set_run_inserted_at(~U[2026-06-13 10:00:00.000000Z])

      result = SymphonyElixir.Storage.get_work_run_by_linear_identifier("COD-42")

      assert result != nil
      assert result.id == newer.id
      refute result.id == older.id
    end

    @tag :db
    test "returns nil for an unknown identifier", %{project: _project} do
      assert nil == SymphonyElixir.Storage.get_work_run_by_linear_identifier("NOPE-999")
    end
  end

  describe "list_work_events_for_run/2, encode_work_event_cursor/1, decode_work_event_cursor/1" do
    @tag :db
    setup :checkout_repo

    setup do
      {:ok, project} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "events-proj",
          linear_project_slug: "events-linear",
          github_owner: "acme",
          github_repo: "widget",
          github_base_branch: "main",
          linear_human_review_state: "Human Review",
          config_version: 1,
          config: %{}
        })

      {:ok, run} =
        SymphonyElixir.Storage.create_work_run(%{
          project_id: project.id,
          type: "implementation",
          status: "running",
          agent_backend: "codex",
          payload: %{}
        })

      {:ok, other_run} =
        SymphonyElixir.Storage.create_work_run(%{
          project_id: project.id,
          type: "implementation",
          status: "running",
          agent_backend: "codex",
          payload: %{}
        })

      %{project: project, run: run, other_run: other_run}
    end

    defp insert_event(project_id, work_run_id, type) do
      {:ok, event} =
        SymphonyElixir.Storage.append_event(%{
          project_id: project_id,
          work_run_id: work_run_id,
          type: type,
          payload: %{}
        })

      event
    end

    defp set_event_inserted_at(event, inserted_at) do
      import Ecto.Query

      SymphonyElixir.Repo.update_all(
        from(e in SymphonyElixir.Storage.WorkEvent, where: e.id == ^event.id),
        set: [inserted_at: inserted_at]
      )

      %{event | inserted_at: inserted_at}
    end

    @tag :db
    test "returns events for a run in ascending order (oldest first)", %{project: project, run: run} do
      e1 = insert_event(project.id, run.id, "queued") |> set_event_inserted_at(~U[2026-06-13 08:00:01.000000Z])
      e2 = insert_event(project.id, run.id, "started") |> set_event_inserted_at(~U[2026-06-13 08:00:02.000000Z])
      e3 = insert_event(project.id, run.id, "agent_update") |> set_event_inserted_at(~U[2026-06-13 08:00:03.000000Z])

      events = SymphonyElixir.Storage.list_work_events_for_run(run.id)

      ids = Enum.map(events, & &1.id)
      assert ids == [e1.id, e2.id, e3.id]
    end

    @tag :db
    test "scoped to work_run_id — does not return events for other runs", %{project: project, run: run, other_run: other_run} do
      insert_event(project.id, run.id, "queued")
      other_event = insert_event(project.id, other_run.id, "queued")

      events = SymphonyElixir.Storage.list_work_events_for_run(run.id)

      ids = Enum.map(events, & &1.id)
      refute other_event.id in ids
    end

    @tag :db
    test "cursor pagination returns correct second page without overlap (ascending)", %{project: project, run: run} do
      e1 = insert_event(project.id, run.id, "e1") |> set_event_inserted_at(~U[2026-06-13 09:00:01.000000Z])
      e2 = insert_event(project.id, run.id, "e2") |> set_event_inserted_at(~U[2026-06-13 09:00:02.000000Z])
      e3 = insert_event(project.id, run.id, "e3") |> set_event_inserted_at(~U[2026-06-13 09:00:03.000000Z])

      # page 1: page_size=2, overfetch gives 3 rows [e1, e2, e3]
      page1 = SymphonyElixir.Storage.list_work_events_for_run(run.id, %{page_size: 2})
      assert length(page1) == 3

      # pivot = last visible row = index 1 (e2)
      pivot = Enum.at(page1, 1)
      cursor = SymphonyElixir.Storage.encode_work_event_cursor(pivot)

      page2 = SymphonyElixir.Storage.list_work_events_for_run(run.id, %{page_size: 2, cursor: cursor})

      page2_ids = Enum.map(page2, & &1.id)
      assert e3.id in page2_ids
      refute e1.id in page2_ids
      refute e2.id in page2_ids
    end

    @tag :db
    test "invalid cursor string falls back to first page", %{project: project, run: run} do
      for i <- 1..3 do
        insert_event(project.id, run.id, "type-#{i}")
      end

      no_cursor = SymphonyElixir.Storage.list_work_events_for_run(run.id)
      bad_cursor = SymphonyElixir.Storage.list_work_events_for_run(run.id, %{cursor: "!not-valid-base64!!"})

      assert Enum.map(no_cursor, & &1.id) == Enum.map(bad_cursor, & &1.id)
    end

    @tag :db
    test "overfetches page_size + 1 rows so caller can detect next page", %{project: project, run: run} do
      for i <- 1..3 do
        insert_event(project.id, run.id, "t#{i}")
      end

      rows = SymphonyElixir.Storage.list_work_events_for_run(run.id, %{page_size: 2})
      assert length(rows) == 3
    end

    test "encode_work_event_cursor / decode_work_event_cursor round-trip" do
      fake_event = %SymphonyElixir.Storage.WorkEvent{
        id: "550e8400-e29b-41d4-a716-446655440000",
        inserted_at: ~U[2026-06-13 10:00:00.123456Z]
      }

      cursor = SymphonyElixir.Storage.encode_work_event_cursor(fake_event)
      assert is_binary(cursor)
      refute String.ends_with?(cursor, "=")

      assert {:ok, decoded} = SymphonyElixir.Storage.decode_work_event_cursor(cursor)
      assert decoded.id == fake_event.id
      assert decoded.inserted_at == fake_event.inserted_at
    end

    test "decode_work_event_cursor returns :error for garbage input" do
      assert :error == SymphonyElixir.Storage.decode_work_event_cursor("totally-not-valid")
      assert :error == SymphonyElixir.Storage.decode_work_event_cursor("")
    end

    test "decode_work_event_cursor returns :error for valid base64url but invalid JSON structure" do
      bad = Base.url_encode64(~s({"foo":"bar"}), padding: false)
      assert :error == SymphonyElixir.Storage.decode_work_event_cursor(bad)
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

  describe "get_artifact/1" do
    @tag :db
    setup :checkout_repo

    setup do
      {:ok, project} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "artifact-get-proj",
          linear_project_slug: "ag-linear",
          github_owner: "acme",
          github_repo: "widget",
          github_base_branch: "main",
          linear_human_review_state: "Human Review",
          config_version: 1,
          config: %{}
        })

      {:ok, run} =
        SymphonyElixir.Storage.create_work_run(%{
          project_id: project.id,
          type: "implementation",
          status: "running",
          agent_backend: "codex",
          payload: %{}
        })

      %{project: project, run: run}
    end

    @tag :db
    test "returns the artifact when found", %{project: project, run: run} do
      {:ok, artifact} =
        SymphonyElixir.Storage.create_artifact(%{
          project_id: project.id,
          work_run_id: run.id,
          kind: "screenshot",
          path: "/tmp/screenshot.png",
          metadata: %{}
        })

      result = SymphonyElixir.Storage.get_artifact(artifact.id)
      assert result != nil
      assert result.id == artifact.id
      assert result.kind == "screenshot"
    end

    @tag :db
    test "returns nil for an unknown but valid UUID" do
      unknown_id = Ecto.UUID.generate()
      assert nil == SymphonyElixir.Storage.get_artifact(unknown_id)
    end

    @tag :db
    test "returns nil for garbage (non-UUID) input" do
      assert nil == SymphonyElixir.Storage.get_artifact("not-a-uuid")
      assert nil == SymphonyElixir.Storage.get_artifact("")
      assert nil == SymphonyElixir.Storage.get_artifact("12345")
    end
  end

  describe "list_artifacts_for_project/1" do
    @tag :db
    setup :checkout_repo

    setup do
      {:ok, project} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "artifacts-for-proj",
          linear_project_slug: "afp-linear",
          github_owner: "acme",
          github_repo: "widget",
          github_base_branch: "main",
          linear_human_review_state: "Human Review",
          config_version: 1,
          config: %{}
        })

      {:ok, other_project} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "other-artifacts-proj",
          linear_project_slug: "oap-linear",
          github_owner: "acme",
          github_repo: "other",
          github_base_branch: "main",
          linear_human_review_state: "Human Review",
          config_version: 1,
          config: %{}
        })

      {:ok, run} =
        SymphonyElixir.Storage.create_work_run(%{
          project_id: project.id,
          type: "implementation",
          status: "running",
          agent_backend: "codex",
          payload: %{}
        })

      {:ok, other_run} =
        SymphonyElixir.Storage.create_work_run(%{
          project_id: other_project.id,
          type: "implementation",
          status: "running",
          agent_backend: "codex",
          payload: %{}
        })

      %{project: project, other_project: other_project, run: run, other_run: other_run}
    end

    defp insert_artifact(project_id, work_run_id, kind) do
      {:ok, artifact} =
        SymphonyElixir.Storage.create_artifact(%{
          project_id: project_id,
          work_run_id: work_run_id,
          kind: kind,
          path: "/tmp/#{kind}.png",
          metadata: %{}
        })

      artifact
    end

    defp set_artifact_inserted_at(artifact, inserted_at) do
      import Ecto.Query

      SymphonyElixir.Repo.update_all(
        from(a in SymphonyElixir.Storage.Artifact, where: a.id == ^artifact.id),
        set: [inserted_at: inserted_at]
      )

      %{artifact | inserted_at: inserted_at}
    end

    @tag :db
    test "returns artifacts for the project in ascending inserted_at order", %{project: project, run: run} do
      a1 = insert_artifact(project.id, run.id, "screenshot") |> set_artifact_inserted_at(~U[2026-06-13 10:00:01.000000Z])
      a2 = insert_artifact(project.id, run.id, "report") |> set_artifact_inserted_at(~U[2026-06-13 10:00:02.000000Z])
      a3 = insert_artifact(project.id, run.id, "trace") |> set_artifact_inserted_at(~U[2026-06-13 10:00:03.000000Z])

      artifacts = SymphonyElixir.Storage.list_artifacts_for_project(project.id)
      ids = Enum.map(artifacts, & &1.id)

      assert ids == [a1.id, a2.id, a3.id]
    end

    @tag :db
    test "does not return artifacts from other projects", %{project: project, run: run, other_project: other_project, other_run: other_run} do
      insert_artifact(project.id, run.id, "screenshot")
      other_artifact = insert_artifact(other_project.id, other_run.id, "screenshot")

      artifacts = SymphonyElixir.Storage.list_artifacts_for_project(project.id)
      ids = Enum.map(artifacts, & &1.id)

      refute other_artifact.id in ids
    end

    @tag :db
    test "preloads work_run association (non-nil)", %{project: project, run: run} do
      insert_artifact(project.id, run.id, "screenshot")

      [artifact] = SymphonyElixir.Storage.list_artifacts_for_project(project.id)
      assert artifact.work_run != nil
      assert %SymphonyElixir.Storage.WorkRun{} = artifact.work_run
      assert artifact.work_run.id == run.id
    end
  end

  describe "list_work_events_for_project/2" do
    @tag :db
    setup :checkout_repo

    setup do
      {:ok, project} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "events-proj-wide",
          linear_project_slug: "epw-linear",
          github_owner: "acme",
          github_repo: "widget",
          github_base_branch: "main",
          linear_human_review_state: "Human Review",
          config_version: 1,
          config: %{}
        })

      {:ok, other_project} =
        SymphonyElixir.Storage.upsert_project(%{
          slug: "other-events-proj",
          linear_project_slug: "oep-linear",
          github_owner: "acme",
          github_repo: "other",
          github_base_branch: "main",
          linear_human_review_state: "Human Review",
          config_version: 1,
          config: %{}
        })

      {:ok, run1} =
        SymphonyElixir.Storage.create_work_run(%{
          project_id: project.id,
          type: "implementation",
          status: "running",
          agent_backend: "codex",
          payload: %{}
        })

      {:ok, run2} =
        SymphonyElixir.Storage.create_work_run(%{
          project_id: project.id,
          type: "implementation",
          status: "running",
          agent_backend: "codex",
          payload: %{}
        })

      {:ok, other_run} =
        SymphonyElixir.Storage.create_work_run(%{
          project_id: other_project.id,
          type: "implementation",
          status: "running",
          agent_backend: "codex",
          payload: %{}
        })

      %{project: project, other_project: other_project, run1: run1, run2: run2, other_run: other_run}
    end

    defp insert_project_event(project_id, work_run_id, type) do
      {:ok, event} =
        SymphonyElixir.Storage.append_event(%{
          project_id: project_id,
          work_run_id: work_run_id,
          type: type,
          payload: %{}
        })

      event
    end

    defp set_project_event_inserted_at(event, inserted_at) do
      import Ecto.Query

      SymphonyElixir.Repo.update_all(
        from(e in SymphonyElixir.Storage.WorkEvent, where: e.id == ^event.id),
        set: [inserted_at: inserted_at]
      )

      %{event | inserted_at: inserted_at}
    end

    @tag :db
    test "returns events for a project across multiple runs in ascending order", %{project: project, run1: run1, run2: run2} do
      e1 = insert_project_event(project.id, run1.id, "queued") |> set_project_event_inserted_at(~U[2026-06-13 08:00:01.000000Z])
      e2 = insert_project_event(project.id, run2.id, "started") |> set_project_event_inserted_at(~U[2026-06-13 08:00:02.000000Z])
      e3 = insert_project_event(project.id, run1.id, "agent_update") |> set_project_event_inserted_at(~U[2026-06-13 08:00:03.000000Z])

      events = SymphonyElixir.Storage.list_work_events_for_project(project.id)
      ids = Enum.map(events, & &1.id)

      assert ids == [e1.id, e2.id, e3.id]
    end

    @tag :db
    test "scoped to project_id — does not return events from other projects", %{project: project, run1: run1, other_project: other_project, other_run: other_run} do
      insert_project_event(project.id, run1.id, "queued")
      other_event = insert_project_event(other_project.id, other_run.id, "queued")

      events = SymphonyElixir.Storage.list_work_events_for_project(project.id)
      ids = Enum.map(events, & &1.id)

      refute other_event.id in ids
    end

    @tag :db
    test "overfetches page_size + 1 rows so caller can detect next page", %{project: project, run1: run1} do
      for i <- 1..3 do
        insert_project_event(project.id, run1.id, "t#{i}")
      end

      rows = SymphonyElixir.Storage.list_work_events_for_project(project.id, %{page_size: 2})
      assert length(rows) == 3
    end

    @tag :db
    test "cursor pagination returns correct second page without overlap", %{project: project, run1: run1} do
      e1 = insert_project_event(project.id, run1.id, "e1") |> set_project_event_inserted_at(~U[2026-06-13 09:00:01.000000Z])
      e2 = insert_project_event(project.id, run1.id, "e2") |> set_project_event_inserted_at(~U[2026-06-13 09:00:02.000000Z])
      e3 = insert_project_event(project.id, run1.id, "e3") |> set_project_event_inserted_at(~U[2026-06-13 09:00:03.000000Z])

      # page 1: page_size=2, overfetch gives 3 rows [e1, e2, e3]
      page1 = SymphonyElixir.Storage.list_work_events_for_project(project.id, %{page_size: 2})
      assert length(page1) == 3

      # pivot = last visible row = index 1 (e2)
      pivot = Enum.at(page1, 1)
      cursor = SymphonyElixir.Storage.encode_work_event_cursor(pivot)

      page2 = SymphonyElixir.Storage.list_work_events_for_project(project.id, %{page_size: 2, cursor: cursor})

      page2_ids = Enum.map(page2, & &1.id)
      assert e3.id in page2_ids
      refute e1.id in page2_ids
      refute e2.id in page2_ids
    end

    @tag :db
    test "invalid cursor string falls back to first page", %{project: project, run1: run1} do
      for i <- 1..3 do
        insert_project_event(project.id, run1.id, "type-#{i}")
      end

      no_cursor = SymphonyElixir.Storage.list_work_events_for_project(project.id)
      bad_cursor = SymphonyElixir.Storage.list_work_events_for_project(project.id, %{cursor: "!not-valid-base64!!"})

      assert Enum.map(no_cursor, & &1.id) == Enum.map(bad_cursor, & &1.id)
    end
  end
end
