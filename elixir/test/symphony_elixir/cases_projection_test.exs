defmodule SymphonyElixir.CasesProjectionTest do
  use SymphonyElixir.TestSupport

  import SymphonyElixir.CasesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Cases
  alias SymphonyElixir.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  defp list(opts \\ []) do
    Cases.list(Keyword.merge([filter: "all", column: nil, q: nil, project_id: nil, limit: 25, after: nil], opts))
  end

  defp only(ref, opts \\ []) do
    list(opts).items |> Enum.find(&(&1.ref == ref))
  end

  defp after_position([iso, ref]) do
    {:ok, datetime, 0} = DateTime.from_iso8601(iso)
    {datetime, ref}
  end

  describe "pagination and aggregates (T18.1)" do
    test "60 cases in one column page by 25 with total 60 and complete project sums" do
      main = scope!()
      other = scope!()
      empty = project!()

      for index <- 1..60, do: ready_case!(main, %{detected_at: at(index), jira_key: "OPS-#{index}"}, published?: false)
      for index <- 1..3, do: intake_case!(other, %{detected_at: at(index)})

      first = list(column: "decision")
      assert length(first.items) == 25
      assert first.total == 60
      assert Enum.all?(first.items, &(&1.column == "decision"))
      assert first.counts == %{all: 63, decision: 60, analysis: 0, done: 0, detected: 3}

      totals = Map.new(first.project_counts, &{&1.project_id, &1.total})
      assert totals[main.project.id] == 60
      assert totals[other.project.id] == 3
      assert totals[empty.id] == 0
      assert first.project_counts |> Enum.map(& &1.total) |> Enum.sum() == 63

      second = list(column: "decision", after: after_position(first.next_position))
      third = list(column: "decision", after: after_position(second.next_position))

      assert length(second.items) == 25
      assert length(third.items) == 10
      assert third.next_position == nil

      refs = Enum.map(first.items ++ second.items ++ third.items, & &1.ref)
      assert length(Enum.uniq(refs)) == 60

      detected = Enum.map(first.items ++ second.items ++ third.items, & &1.detected_at)
      assert detected == Enum.sort(detected, {:desc, DateTime})
    end

    test "ties on detected_at are ordered by ref and never skipped across pages" do
      main = scope!()
      for _index <- 1..7, do: intake_case!(main, %{detected_at: at(5)})

      first = list(limit: 3)
      second = list(limit: 3, after: after_position(first.next_position))
      third = list(limit: 3, after: after_position(second.next_position))

      refs = Enum.map(first.items ++ second.items ++ third.items, & &1.ref)
      assert refs == Enum.sort(refs)
      assert length(Enum.uniq(refs)) == 7
    end

    test "counts follow project and q but ignore the active filter and column" do
      main = scope!()
      other = scope!()
      ready_case!(main, %{title: "Eksport raportu"}, published?: false)
      intake_case!(main, %{title: "Eksport faktur", analysis_status: "running"})
      intake_case!(other, %{title: "Eksport HR"})

      page = list(project_id: main.project.id, q: "eksport", filter: "decision")
      assert page.total == 1
      assert page.counts == %{all: 2, decision: 1, analysis: 1, done: 0, detected: 0}
      assert Enum.map(page.items, & &1.title) == ["Eksport raportu"]
    end
  end

  describe "union of intake cases and work runs (T18.2)" do
    test "keeps only the newest work run per source key" do
      %{project: project} = scope!()
      linear_id = Ecto.UUID.generate()

      _old = work_run!(project, %{linear_issue_id: linear_id, linear_identifier: "LIN-1", status: "failed", inserted_at: at(30)})
      newest = work_run!(project, %{linear_issue_id: linear_id, linear_identifier: "LIN-1", status: "running", inserted_at: at(10)})
      by_dedupe = work_run!(project, %{dedupe_key: "github:ci:1", type: "ci_fix", status: "queued", inserted_at: at(20)})
      bare_one = work_run!(project, %{type: "code_review", status: "completed", inserted_at: at(40)})
      bare_two = work_run!(project, %{type: "code_review", status: "completed", inserted_at: at(41)})

      refs = list().items |> Enum.map(& &1.ref) |> Enum.sort()
      assert refs == Enum.sort(Enum.map([newest, by_dedupe, bare_one, bare_two], &"run_#{&1.id}"))
      assert only("run_#{newest.id}").column == "analyzing"
    end

    test "hides jira_analysis runs and implementation runs linked to an intake case" do
      scope = scope!()
      intake_case = ready_case!(scope, %{repair_approved_at: at(-1), repair_approved_version: 1})

      work_run!(scope.project, %{type: "jira_analysis", status: "running", linear_issue_id: intake_case.linear_issue_id})
      work_run!(scope.project, %{type: "implementation", status: "running", linear_issue_id: intake_case.linear_issue_id})

      page = list()
      assert Enum.map(page.items, & &1.ref) == ["jira_#{intake_case.id}"]
      assert page.counts.all == 1
    end
  end

  describe "refs and search (T18.3)" do
    test "refs are jira_<uuid> and run_<uuid>" do
      scope = scope!()
      intake_case = intake_case!(scope)
      run = work_run!(scope.project, %{inserted_at: at(3)})

      assert Enum.map(list().items, & &1.ref) == ["jira_#{intake_case.id}", "run_#{run.id}"]
    end

    test "search is trimmed, case-insensitive and matches title, Jira key and Linear identifier" do
      scope = scope!()
      by_title = intake_case!(scope, %{title: "Błąd 504 w eksporcie", detected_at: at(1)})
      by_key = intake_case!(scope, %{jira_key: "FIN-87", detected_at: at(2)})
      run = work_run!(scope.project, %{linear_identifier: "LIN-303", inserted_at: at(3)})
      literal = intake_case!(scope, %{title: "Rabat 100% dla klienta", detected_at: at(4)})

      assert Enum.map(list(q: "eksporcie").items, & &1.ref) == ["jira_#{by_title.id}"]
      assert Enum.map(list(q: "fin-87").items, & &1.ref) == ["jira_#{by_key.id}"]
      assert Enum.map(list(q: "lin-303").items, & &1.ref) == ["run_#{run.id}"]
      assert Enum.map(list(q: "100%").items, & &1.ref) == ["jira_#{literal.id}"]
      assert list(q: "_%").items == []
    end
  end

  describe "status precedence (T18.4)" do
    test "a failed required delivery wins over a running analysis and survives acknowledge" do
      scope = scope!()
      running = intake_case!(scope, %{analysis_status: "running"})
      delivery!(running, "email", "failed")

      assert %{column: "decision", attention: %{code: "delivery_failed"}} = only("jira_#{running.id}")

      acknowledged = ready_case!(scope, %{acknowledged_at: at(-1)})
      delivery!(acknowledged, "sms", "unknown", %{recipient: "+19995550123"})
      assert %{column: "decision", attention: %{code: "delivery_unknown"}} = only("jira_#{acknowledged.id}")

      retrying = intake_case!(scope, %{analysis_status: "queued"})
      delivery!(retrying, "linear_create", "retry_wait")
      assert %{column: "decision", attention: %{code: "delivery_retry_wait"}} = only("jira_#{retrying.id}")
    end

    test "an approved repair maps its newest implementation run" do
      scope = scope!()
      waiting = ready_case!(scope, %{repair_approved_at: at(-1), repair_approved_version: 1})
      assert %{column: "detected", execution_mode: "repair_approved"} = only("jira_#{waiting.id}")

      running = ready_case!(scope, %{repair_approved_at: at(-1), repair_approved_version: 1})
      work_run!(scope.project, %{status: "failed", linear_issue_id: running.linear_issue_id, inserted_at: at(20)})
      work_run!(scope.project, %{status: "running", linear_issue_id: running.linear_issue_id, inserted_at: at(10)})
      assert %{column: "analyzing", status_label: "Naprawa w toku"} = only("jira_#{running.id}")

      done = ready_case!(scope, %{repair_approved_at: at(-1), repair_approved_version: 1})
      work_run!(scope.project, %{status: "completed", linear_issue_id: done.linear_issue_id})
      assert %{column: "handed_off"} = only("jira_#{done.id}")
    end

    test "analysis states map running, queued, ready and needs_input" do
      scope = scope!()
      running = intake_case!(scope, %{analysis_status: "running"})
      queued = intake_case!(scope, %{analysis_status: "queued"})
      waiting_linear = intake_case!(scope, %{analysis_status: "queued", linear_confirmed_at: nil})
      ready = ready_case!(scope)
      needs_input = intake_case!(scope, %{analysis_status: "needs_input"})
      analysis_failed = intake_case!(scope, %{analysis_status: "failed"})

      assert %{column: "analyzing", status_label: "Analiza w toku"} = only("jira_#{running.id}")
      assert %{column: "detected", status_label: "Oczekuje na analizę"} = only("jira_#{queued.id}")
      assert %{column: "detected", linear: nil} = only("jira_#{waiting_linear.id}")
      assert %{column: "decision", status_label: "Analiza gotowa", attention: nil} = only("jira_#{ready.id}")
      assert %{column: "decision", attention: %{code: "analysis_needs_input"}} = only("jira_#{needs_input.id}")
      assert %{column: "decision", attention: %{code: "analysis_failed"}} = only("jira_#{analysis_failed.id}")
    end

    test "only an acknowledged case with a published comment is handed off" do
      scope = scope!()
      handed_off = ready_case!(scope, %{acknowledged_at: at(-1)})
      unpublished = ready_case!(scope, %{acknowledged_at: at(-1)}, published?: false)
      not_acknowledged = ready_case!(scope)

      assert %{column: "handed_off", status_label: "Komentarz w Jira"} = only("jira_#{handed_off.id}")
      assert %{column: "decision"} = only("jira_#{unpublished.id}")
      assert %{column: "decision"} = only("jira_#{not_acknowledged.id}")
    end

    test "failures of an older analysis version do not block the current one; paused is attention only" do
      scope = scope!()
      reanalyzed = intake_case!(scope, %{analysis_version: 2, analysis_status: "running"})
      delivery!(reanalyzed, "analysis", "failed", %{version: 1})
      assert %{column: "analyzing", attention: nil} = only("jira_#{reanalyzed.id}")

      paused = intake_case!(scope, %{analysis_status: "queued"})
      delivery!(paused, "email", "paused")
      assert %{column: "detected", attention: %{code: "dependency_paused"}} = only("jira_#{paused.id}")
    end
  end

  describe "visibility of incomplete data (T18.5)" do
    test "legacy runs without Linear keep a deterministic title and stay visible" do
      %{project: project} = scope!()
      titled = work_run!(project, %{payload: %{"title" => "Payload title"}, inserted_at: at(1)})
      issue_titled = work_run!(project, %{payload: %{"issue" => %{"title" => "Issue title", "priority" => 2}}, inserted_at: at(2)})
      identifier = work_run!(project, %{linear_identifier: "LIN-304", inserted_at: at(3)})
      bare = work_run!(project, %{type: "ci_fix", inserted_at: at(4)})

      assert only("run_#{titled.id}").title == "Payload title"
      assert %{title: "Issue title", priority: %{id: "2", label: "Wysoki", tone: "high"}} = only("run_#{issue_titled.id}")
      assert %{title: "LIN-304", linear: nil, jira: nil, kind: "agent_work"} = only("run_#{identifier.id}")
      assert only("run_#{bare.id}").title == "ci_fix · " <> String.slice(bare.id, 0, 8)
      assert only("run_#{bare.id}").priority == %{id: nil, label: "Brak priorytetu", tone: "normal"}
    end

    test "unknown statuses land in decision with the literal status" do
      %{project: project} = scope!()
      run = work_run!(project, %{status: "awaiting_owner"})

      assert only("run_#{run.id}") |> Map.take([:column, :status_label, :attention]) == %{
               column: "decision",
               status_label: "awaiting_owner",
               attention: %{code: "unknown_status", message: "Nieznany status przebiegu: awaiting_owner"}
             }
    end

    test "a case without description and a failed publication stay visible" do
      scope = scope!()
      no_description = intake_case!(scope, %{description_text: ""})
      failed_publication = ready_case!(scope, %{acknowledged_at: at(-1)}, published?: false)
      delivery!(failed_publication, "jira_comment", "failed")

      assert only("jira_#{no_description.id}")
      assert %{column: "decision", attention: %{code: "publication_failed"}} = only("jira_#{failed_publication.id}")
      assert {:ok, %{case: %{description_text: ""}}} = Cases.fetch("jira_#{no_description.id}")
    end

    test "every legacy status of the T01 table maps to its column" do
      %{project: project} = scope!()

      cases = [
        {"queued", nil, "detected"},
        {"retrying", nil, "detected"},
        {"running", nil, "analyzing"},
        {"blocked", "operator review", "decision"},
        {"failed", "worker failed", "decision"},
        {"retrying", "retry exhausted", "decision"},
        {"stopped", "stopped by operator", "decision"},
        {"human_review", "awaiting operator", "decision"},
        {"completed", nil, "handed_off"},
        {"succeeded", nil, "handed_off"},
        {"handed_off", nil, "handed_off"},
        {"cancelled", nil, "handed_off"},
        {"awaiting_owner", nil, "decision"}
      ]

      runs =
        for {{status, error, column}, index} <- Enum.with_index(cases) do
          payload = if error, do: %{"error_code" => error}, else: %{}
          {work_run!(project, %{status: status, payload: payload, inserted_at: at(index)}), column}
        end

      for {run, column} <- runs do
        assert only("run_#{run.id}").column == column, "status #{run.status}"
      end
    end

    test "Jira priorities keep their original ID and name with a normal tone when no ranking is stored" do
      scope = scope!()
      intake_case = intake_case!(scope, %{priority_id: "10001", priority_name: "Blocker"})

      assert only("jira_#{intake_case.id}").priority == %{id: "10001", label: "Blocker", tone: "normal"}
    end
  end

  describe "detail and history (T18.6)" do
    test "events are paged by 50 in occurrence order with masked recipients" do
      scope = scope!()
      intake_case = intake_case!(scope)
      email = delivery!(intake_case, "email", "succeeded", %{recipient: "oncall@example.test"})

      for index <- 1..60 do
        event!(intake_case, "delivery_attempt", %{"delivery_id" => email.id, "operation" => "email"}, at(-index))
      end

      assert {:ok, first} = Cases.events("jira_#{intake_case.id}", limit: 50, after: nil)
      assert length(first.items) == 50
      assert [%{operation: "email", recipient: "o***@example.test"} | _] = first.items
      refute inspect(first.items) =~ "oncall@example.test"

      {:ok, occurred_at, 0} = DateTime.from_iso8601(hd(first.next_position))
      assert {:ok, second} = Cases.events("jira_#{intake_case.id}", limit: 50, after: {occurred_at, List.last(first.next_position)})
      assert length(second.items) == 10
      assert second.next_position == nil
    end

    test "unknown refs are not found" do
      assert Cases.fetch("jira_#{Ecto.UUID.generate()}") == {:error, :not_found}
      assert Cases.fetch("run_#{Ecto.UUID.generate()}") == {:error, :not_found}
      assert Cases.fetch("nonsense") == {:error, :not_found}
      assert Cases.events("run_#{Ecto.UUID.generate()}", limit: 50, after: nil) == {:error, :not_found}
    end
  end
end
