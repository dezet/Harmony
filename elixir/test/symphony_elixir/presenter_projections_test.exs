defmodule SymphonyElixirWeb.PresenterProjectionsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Storage.{PullRequestLink, WorkRun}
  alias SymphonyElixirWeb.Presenter

  # ---------------------------------------------------------------------------
  # Helpers: minimal snapshot entry maps (atom-keyed, like the Orchestrator
  # produces) and minimal project / work-run structs.
  # ---------------------------------------------------------------------------

  defp project_struct(overrides \\ %{}) do
    base = %{
      __struct__: SymphonyElixir.Storage.Project,
      id: "proj-uuid-1",
      slug: "alpha",
      github_owner: "acme",
      github_repo: "portal",
      github_base_branch: "main",
      linear_project_slug: "alpha-linear",
      linear_team_key: "COD",
      linear_human_review_state: "Human Review",
      config_version: 3
    }

    Map.merge(base, overrides)
  end

  # A running entry that belongs to the project by id AND slug.
  defp running_entry(overrides \\ %{}) do
    base = %{
      issue_id: "issue-running-1",
      identifier: "COD-10",
      state: "running",
      project_id: "proj-uuid-1",
      project_name: "Alpha",
      project_slug: "alpha",
      worker_host: "host1",
      workspace_path: "/ws/cod-10",
      session_id: "sess-1",
      turn_count: 5,
      last_codex_event: "turn_end",
      last_codex_message: nil,
      started_at: ~U[2026-06-10 08:00:00Z],
      last_codex_timestamp: ~U[2026-06-10 09:00:00Z],
      codex_input_tokens: 100,
      codex_output_tokens: 50,
      codex_total_tokens: 150
    }

    Map.merge(base, overrides)
  end

  defp retry_entry(overrides \\ %{}) do
    base = %{
      issue_id: "issue-retry-1",
      identifier: "COD-11",
      project_id: "proj-uuid-1",
      project_name: "Alpha",
      project_slug: "alpha",
      attempt: 2,
      due_in_ms: 60_000,
      error: "some error",
      worker_host: "host1",
      workspace_path: "/ws/cod-11"
    }

    Map.merge(base, overrides)
  end

  defp blocked_entry(overrides \\ %{}) do
    base = %{
      issue_id: "issue-blocked-1",
      identifier: "COD-12",
      state: "blocked",
      project_id: "proj-uuid-1",
      project_name: "Alpha",
      project_slug: "alpha",
      error: "human review required",
      worker_host: "host1",
      workspace_path: "/ws/cod-12",
      session_id: "sess-2",
      blocked_at: ~U[2026-06-10 10:00:00Z],
      last_codex_event: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil
    }

    Map.merge(base, overrides)
  end

  defp other_project_entry do
    %{
      issue_id: "issue-other-1",
      identifier: "OTH-1",
      state: "running",
      project_id: "proj-uuid-OTHER",
      project_name: "Other",
      project_slug: "other",
      worker_host: "host2",
      workspace_path: "/ws/oth-1",
      session_id: "sess-other",
      turn_count: 1,
      last_codex_event: nil,
      last_codex_message: nil,
      started_at: ~U[2026-06-10 08:00:00Z],
      last_codex_timestamp: ~U[2026-06-10 09:00:00Z],
      codex_input_tokens: 10,
      codex_output_tokens: 5,
      codex_total_tokens: 15
    }
  end

  defp snapshot(running \\ [], retrying \\ [], blocked \\ []) do
    %{running: running, retrying: retrying, blocked: blocked}
  end

  defp pr_link(overrides \\ %{}) do
    base = %PullRequestLink{
      id: "pr-uuid-1",
      project_id: "proj-uuid-1",
      github_owner: "acme",
      github_repo: "portal",
      github_pr_number: 42,
      github_head_sha: "abc123",
      github_head_ref: "cod-10-feature",
      github_base_ref: "main",
      linear_issue_id: "issue-running-1",
      linear_identifier: "COD-10",
      linear_url: "https://linear.app/acme/issue/COD-10",
      metadata: %{"ci_status" => "pass"}
    }

    Map.merge(base, overrides)
  end

  defp work_run(overrides \\ %{}) do
    base = %WorkRun{
      id: "run-uuid-1",
      project_id: "proj-uuid-1",
      type: "implementation",
      status: "completed",
      dedupe_key: "linear:COD-10",
      github_owner: "acme",
      github_repo: "portal",
      github_pr_number: 42,
      github_head_sha: "abc123",
      github_head_ref: "cod-10-feature",
      github_base_ref: "main",
      linear_issue_id: "issue-running-1",
      linear_identifier: "COD-10",
      linear_url: "https://linear.app/acme/issue/COD-10",
      agent_backend: "codex",
      payload: %{"some" => "data"},
      inserted_at: ~U[2026-06-10 08:00:00.000000Z],
      updated_at: ~U[2026-06-10 09:00:00.000000Z]
    }

    Map.merge(base, overrides)
  end

  # ===========================================================================
  # project_summary_payload/3
  # ===========================================================================

  describe "project_summary_payload/3 — project block" do
    test "includes all required project fields" do
      proj = project_struct()
      result = Presenter.project_summary_payload(proj, snapshot(), [])

      assert %{
               id: "proj-uuid-1",
               slug: "alpha",
               github_owner: "acme",
               github_repo: "portal",
               github_base_branch: "main",
               linear_project_slug: "alpha-linear",
               linear_team_key: "COD",
               linear_human_review_state: "Human Review",
               config_version: 3
             } = result.project
    end
  end

  describe "project_summary_payload/3 — entry filtering and project key removal" do
    test "filters running entries belonging to this project by id" do
      proj = project_struct()
      snap = snapshot([running_entry()], [], [])
      result = Presenter.project_summary_payload(proj, snap, [])

      assert length(result.running) == 1
      entry = hd(result.running)
      assert entry.issue_identifier == "COD-10"
      # project key must be absent
      refute Map.has_key?(entry, :project)
    end

    test "excludes running entries from other projects" do
      proj = project_struct()
      snap = snapshot([other_project_entry()], [], [])
      result = Presenter.project_summary_payload(proj, snap, [])

      assert result.running == []
    end

    test "filters by project slug when entry has the same slug but different (nil) id" do
      proj = project_struct()
      # Entry with nil project_id but matching slug — should be included
      entry = running_entry(%{project_id: nil})
      snap = snapshot([entry], [], [])
      result = Presenter.project_summary_payload(proj, snap, [])

      assert length(result.running) == 1
    end

    test "filters retrying entries belonging to this project" do
      proj = project_struct()
      snap = snapshot([], [retry_entry()], [])
      result = Presenter.project_summary_payload(proj, snap, [])

      assert length(result.retrying) == 1
      assert hd(result.retrying).issue_identifier == "COD-11"
      refute Map.has_key?(hd(result.retrying), :project)
    end

    test "excludes retrying entries from other projects" do
      other_retry = retry_entry(%{project_id: "proj-uuid-OTHER", project_slug: "other"})
      proj = project_struct()
      snap = snapshot([], [other_retry], [])
      result = Presenter.project_summary_payload(proj, snap, [])

      assert result.retrying == []
    end

    test "filters blocked entries belonging to this project" do
      proj = project_struct()
      snap = snapshot([], [], [blocked_entry()])
      result = Presenter.project_summary_payload(proj, snap, [])

      assert length(result.blocked) == 1
      assert hd(result.blocked).issue_identifier == "COD-12"
      refute Map.has_key?(hd(result.blocked), :project)
    end

    test "excludes blocked entries from other projects" do
      other_blocked = blocked_entry(%{project_id: "proj-uuid-OTHER", project_slug: "other"})
      proj = project_struct()
      snap = snapshot([], [], [other_blocked])
      result = Presenter.project_summary_payload(proj, snap, [])

      assert result.blocked == []
    end

    test "mixed snapshot: only this project's entries appear in each list" do
      proj = project_struct()

      snap =
        snapshot(
          [running_entry(), other_project_entry()],
          [retry_entry()],
          [blocked_entry()]
        )

      result = Presenter.project_summary_payload(proj, snap, [])

      assert length(result.running) == 1
      assert length(result.retrying) == 1
      assert length(result.blocked) == 1
    end
  end

  describe "project_summary_payload/3 — counts" do
    test "counts reflect the filtered lists" do
      proj = project_struct()
      snap = snapshot([running_entry(), other_project_entry()], [retry_entry()], [blocked_entry()])
      result = Presenter.project_summary_payload(proj, snap, [])

      assert result.counts == %{running: 1, retrying: 1, blocked: 1}
    end

    test "zero counts when snapshot is empty" do
      proj = project_struct()
      result = Presenter.project_summary_payload(proj, snapshot(), [])

      assert result.counts == %{running: 0, retrying: 0, blocked: 0}
    end
  end

  describe "project_summary_payload/3 — human_review_prs" do
    test "projects PR link fields correctly" do
      proj = project_struct()
      link = pr_link()
      result = Presenter.project_summary_payload(proj, snapshot(), [link])

      assert [pr] = result.human_review_prs

      assert pr == %{
               id: "pr-uuid-1",
               github_owner: "acme",
               github_repo: "portal",
               github_pr_number: 42,
               github_head_sha: "abc123",
               github_head_ref: "cod-10-feature",
               github_base_ref: "main",
               linear_identifier: "COD-10",
               linear_url: "https://linear.app/acme/issue/COD-10",
               metadata: %{"ci_status" => "pass"}
             }
    end

    test "nil metadata is preserved as-is" do
      proj = project_struct()
      link = pr_link(%{metadata: nil})
      result = Presenter.project_summary_payload(proj, snapshot(), [link])

      assert [%{metadata: nil}] = result.human_review_prs
    end

    test "empty metadata map is preserved" do
      proj = project_struct()
      link = pr_link(%{metadata: %{}})
      result = Presenter.project_summary_payload(proj, snapshot(), [link])

      assert [%{metadata: %{}}] = result.human_review_prs
    end

    test "returns empty list when no PR links given" do
      proj = project_struct()
      result = Presenter.project_summary_payload(proj, snapshot(), [])

      assert result.human_review_prs == []
    end
  end

  # ===========================================================================
  # work_run_list_payload/2
  # ===========================================================================

  describe "work_run_list_payload/2 — slicing and cursor" do
    test "returns all runs when count <= page_size, next_cursor is nil" do
      runs = [work_run()]
      result = Presenter.work_run_list_payload(runs, 25)

      assert length(result.work_runs) == 1
      assert result.meta.next_cursor == nil
      assert result.meta.page_size == 25
    end

    test "detects overfetch and sets next_cursor when count > page_size" do
      page_size = 2
      run1 = work_run(%{id: "run-1", inserted_at: ~U[2026-06-10 08:00:00.000000Z]})
      run2 = work_run(%{id: "run-2", inserted_at: ~U[2026-06-10 07:00:00.000000Z]})
      run3 = work_run(%{id: "run-3", inserted_at: ~U[2026-06-10 06:00:00.000000Z]})

      # 3 rows fetched for page_size=2 (overfetch by 1)
      result = Presenter.work_run_list_payload([run1, run2, run3], page_size)

      # only first page_size rows visible
      assert length(result.work_runs) == 2
      # next_cursor derived from last visible row (run2, index 1)
      assert is_binary(result.meta.next_cursor)
      # the cursor should decode to run2's inserted_at/id
      assert {:ok, decoded} = SymphonyElixir.Storage.decode_work_run_cursor(result.meta.next_cursor)
      assert decoded.id == "run-2"
    end

    test "no next_cursor when exactly page_size rows returned" do
      page_size = 2
      run1 = work_run(%{id: "run-1"})
      run2 = work_run(%{id: "run-2"})

      result = Presenter.work_run_list_payload([run1, run2], page_size)

      assert length(result.work_runs) == 2
      assert result.meta.next_cursor == nil
    end

    test "empty list returns empty work_runs and nil cursor" do
      result = Presenter.work_run_list_payload([], 25)

      assert result.work_runs == []
      assert result.meta.next_cursor == nil
    end
  end

  describe "work_run_list_payload/2 — field projection" do
    test "includes required fields and omits payload" do
      run = work_run()
      result = Presenter.work_run_list_payload([run], 25)

      assert [projected] = result.work_runs

      assert Map.has_key?(projected, :id)
      assert Map.has_key?(projected, :project_id)
      assert Map.has_key?(projected, :type)
      assert Map.has_key?(projected, :status)
      assert Map.has_key?(projected, :dedupe_key)
      assert Map.has_key?(projected, :github_owner)
      assert Map.has_key?(projected, :github_repo)
      assert Map.has_key?(projected, :github_pr_number)
      assert Map.has_key?(projected, :github_head_sha)
      assert Map.has_key?(projected, :github_head_ref)
      assert Map.has_key?(projected, :github_base_ref)
      assert Map.has_key?(projected, :linear_issue_id)
      assert Map.has_key?(projected, :linear_identifier)
      assert Map.has_key?(projected, :linear_url)
      assert Map.has_key?(projected, :agent_backend)
      assert Map.has_key?(projected, :inserted_at)
      assert Map.has_key?(projected, :updated_at)
      # payload must be omitted
      refute Map.has_key?(projected, :payload)
    end

    test "timestamps are ISO 8601 strings" do
      run = work_run()
      result = Presenter.work_run_list_payload([run], 25)

      [projected] = result.work_runs

      assert projected.inserted_at == "2026-06-10T08:00:00Z"
      assert projected.updated_at == "2026-06-10T09:00:00Z"
    end

    test "field values match the work run" do
      run = work_run()
      result = Presenter.work_run_list_payload([run], 25)

      assert [projected] = result.work_runs
      assert projected.id == "run-uuid-1"
      assert projected.project_id == "proj-uuid-1"
      assert projected.type == "implementation"
      assert projected.status == "completed"
      assert projected.dedupe_key == "linear:COD-10"
      assert projected.github_owner == "acme"
      assert projected.github_repo == "portal"
      assert projected.github_pr_number == 42
      assert projected.agent_backend == "codex"
      assert projected.linear_identifier == "COD-10"
    end
  end
end
