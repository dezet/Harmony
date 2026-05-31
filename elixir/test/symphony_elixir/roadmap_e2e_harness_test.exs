defmodule SymphonyElixir.RoadmapE2EHarnessTest do
  use SymphonyElixir.TestSupport

  import Ecto.Query
  import ExUnit.CaptureIO
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Mix.Tasks.Harmony.RoadmapE2e
  alias SymphonyElixir.Repo
  alias SymphonyElixir.RoadmapE2E
  alias SymphonyElixir.Storage.{Artifact, Blocker, DedupeKey, PullRequestLink, WorkEvent, WorkRun}
  alias SymphonyElixirWeb.Endpoint
  alias SymphonyElixirWeb.Presenter

  @endpoint Endpoint

  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, opts}
    def handle_call(:snapshot, _from, opts), do: {:reply, Keyword.fetch!(opts, :snapshot), opts}
  end

  @tag :db
  setup :checkout_repo

  test "exposes the deterministic roadmap scenarios required by the proof plan" do
    assert RoadmapE2E.scenarios() == [
             "milestone1",
             "milestone2",
             "milestone3_success",
             "milestone3_blocker",
             "milestone4",
             "milestone5"
           ]
  end

  test "milestone1 seeds project-backed implementation work and a PR observation" do
    assert {:ok, summary} = RoadmapE2E.run("milestone1", port: 4101)

    assert_summary_contract(summary, "milestone1", "http://127.0.0.1:4101")
    assert "linear:roadmap-e2e-issue" in summary.dedupe_keys
    assert "implementation run persisted with project_id" in summary.expected_assertions
    assert "pull_request_links contains COD-101 PR #17" in summary.expected_assertions

    assert %WorkRun{payload: payload, github_base_ref: "develop"} =
             stored_work_run(summary.project_id, "linear:roadmap-e2e-issue")

    assert payload["project_id"] == summary.project_id
    assert payload["project_slug"] == "roadmap-e2e"
    assert payload["required_evidence"] == []

    assert %PullRequestLink{
             github_pr_number: 17,
             github_head_sha: "abc123",
             github_head_ref: "cod-101-roadmap-e2e",
             github_base_ref: "develop",
             linear_identifier: "COD-101"
           } = stored_pr_link(summary.project_id, 17)
  end

  test "state payload exposes durable milestone1 records for browser proof" do
    assert {:ok, summary} = RoadmapE2E.run("milestone1", port: 4101)
    orchestrator_name = Module.concat(__MODULE__, :DurableStatePayloadOrchestrator)

    {:ok, _pid} =
      SnapshotOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: empty_snapshot()
      )

    payload = Presenter.state_payload(orchestrator_name, 1_000)

    assert %{durable: durable} = payload

    assert [
             %{
               id: project_id,
               slug: "roadmap-e2e",
               github: %{owner: "dezet", repo: "roadmap-e2e", base_branch: "develop"}
             }
           ] = durable.projects

    assert project_id == summary.project_id

    assert [
             %{
               id: work_run_id,
               project_id: ^project_id,
               type: "implementation",
               status: "queued",
               dedupe_key: "linear:roadmap-e2e-issue",
               linear_identifier: "COD-101"
             }
           ] = durable.work_runs

    assert work_run_id in summary.work_run_ids

    assert [
             %{
               project_id: ^project_id,
               github_pr_number: 17,
               github_head_ref: "cod-101-roadmap-e2e",
               github_base_ref: "develop",
               linear_identifier: "COD-101"
             }
           ] = durable.pull_request_links
  end

  test "milestone1 smoke covers projects page, dashboard, and state api" do
    assert {:ok, summary} = RoadmapE2E.run("milestone1", port: 4101)
    orchestrator_name = Module.concat(__MODULE__, :Milestone1SmokeOrchestrator)

    {:ok, _pid} =
      SnapshotOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: empty_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, projects_html} = live(build_conn(), "/projects")

    assert projects_html =~ "roadmap-e2e"
    assert projects_html =~ "dezet/roadmap-e2e"
    assert projects_html =~ "roadmap-e2e-linear"

    dashboard_html = html_response(get(build_conn(), "/"), 200)

    assert dashboard_html =~ "Symphony Observability"
    assert dashboard_html =~ "Running"

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert Enum.any?(state_payload["durable"]["projects"], &(&1["slug"] == "roadmap-e2e"))

    assert Enum.any?(
             state_payload["durable"]["work_runs"],
             &(&1["id"] in summary.work_run_ids and
                 &1["dedupe_key"] == "linear:roadmap-e2e-issue" and
                 &1["payload"]["project_id"] == summary.project_id)
           )

    assert Enum.any?(
             state_payload["durable"]["pull_request_links"],
             &(&1["github_pr_number"] == 17 and
                 &1["github_head_ref"] == "cod-101-roadmap-e2e" and
                 &1["github_base_ref"] == "develop")
           )
  end

  test "milestone2 records blocked dedupe, blocker, and external-write events" do
    assert {:ok, summary} = RoadmapE2E.run("milestone2", port: 4102)

    dedupe_key = "github-ci-fix:dezet/roadmap-e2e:18:def456:9001"

    assert_summary_contract(summary, "milestone2", "http://127.0.0.1:4102")
    assert dedupe_key in summary.dedupe_keys
    assert "second poll suppressed by blocked dedupe" in summary.expected_assertions

    assert %DedupeKey{status: "blocked", scope: "ci_fix"} = stored_dedupe(summary.project_id, dedupe_key)

    assert %Blocker{
             target_type: "pull_request",
             target_id: "18",
             reason: "unsafe_failed_ci_repair"
           } = stored_blocker(summary.project_id, "pull_request", "18")

    assert ["github_comment_created", "linear_comment_created"] ==
             summary.project_id
             |> stored_events()
             |> Enum.map(& &1.type)
             |> Enum.sort()
  end

  test "milestone2 rerun keeps blocker, dedupe, and external-write events idempotent" do
    assert {:ok, first} = RoadmapE2E.run("milestone2", port: 4102)

    dedupe_key = "github-ci-fix:dezet/roadmap-e2e:18:def456:9001"

    assert {:ok, second} = RoadmapE2E.run("milestone2", port: 4102)

    assert second.project_id == first.project_id
    assert second.work_run_ids == first.work_run_ids
    assert second.dedupe_keys == first.dedupe_keys

    assert 1 == stored_dedupe_count(first.project_id, dedupe_key)
    assert 1 == stored_blocker_count(first.project_id, "pull_request", "18")

    assert ["github_comment_created", "linear_comment_created"] ==
             first.project_id
             |> stored_events()
             |> Enum.map(& &1.type)
             |> Enum.sort()
  end

  test "state payload exposes durable milestone2 blocker, dedupe, and work events" do
    assert {:ok, summary} = RoadmapE2E.run("milestone2", port: 4102)
    orchestrator_name = Module.concat(__MODULE__, :Milestone2StatePayloadOrchestrator)

    {:ok, _pid} =
      SnapshotOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: empty_snapshot()
      )

    payload = Presenter.state_payload(orchestrator_name, 1_000)
    [work_run_id] = summary.work_run_ids

    assert %{durable: durable} = payload

    assert Enum.any?(
             durable.work_runs,
             &(&1.id == work_run_id and &1.status == "blocked" and &1.type == "ci_fix")
           )

    assert Enum.any?(
             durable.dedupe_keys,
             &(&1.key == "github-ci-fix:dezet/roadmap-e2e:18:def456:9001" and &1.status == "blocked")
           )

    assert Enum.any?(
             durable.blockers,
             &(&1.work_run_id == work_run_id and &1.reason == "unsafe_failed_ci_repair" and &1.status == "open")
           )

    assert ["github_comment_created", "linear_comment_created"] ==
             durable.work_events
             |> Enum.filter(&(&1.work_run_id == work_run_id))
             |> Enum.map(& &1.type)
             |> Enum.sort()
  end

  test "milestone3 success and blocker paths seed Human Review handoff evidence" do
    assert {:ok, success} = RoadmapE2E.run("milestone3_success", port: 4103)
    assert_summary_contract(success, "milestone3_success", "http://127.0.0.1:4103")

    assert "linear_state_updated:Human Review" in success.expected_assertions

    assert [%WorkEvent{type: "linear_state_updated", payload: %{"state" => "Human Review"}}] =
             stored_events(success.project_id)

    assert {:ok, blocker} = RoadmapE2E.run("milestone3_blocker", port: 4104)
    assert_summary_contract(blocker, "milestone3_blocker", "http://127.0.0.1:4104")

    assert "missing PR link records blocker" in blocker.expected_assertions
    assert "no scenario sets Linear Done or merges PR" in blocker.expected_assertions

    assert %Blocker{reason: "missing_pull_request_link"} =
             stored_blocker(blocker.project_id, "linear_issue", "roadmap-e2e-m3-blocker")
  end

  test "state payload exposes milestone3 Human Review handoff and blocker evidence" do
    assert {:ok, success} = RoadmapE2E.run("milestone3_success", port: 4103)
    assert {:ok, blocker} = RoadmapE2E.run("milestone3_blocker", port: 4104)
    orchestrator_name = Module.concat(__MODULE__, :Milestone3StatePayloadOrchestrator)

    {:ok, _pid} =
      SnapshotOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: empty_snapshot()
      )

    payload = Presenter.state_payload(orchestrator_name, 1_000)
    [success_run_id] = success.work_run_ids
    [blocker_run_id] = blocker.work_run_ids

    assert %{durable: durable} = payload

    assert Enum.any?(
             durable.work_events,
             &(&1.work_run_id == success_run_id and &1.type == "linear_state_updated" and
                 &1.payload["state"] == "Human Review")
           )

    assert Enum.any?(
             durable.blockers,
             &(&1.work_run_id == blocker_run_id and &1.reason == "missing_pull_request_link" and &1.status == "open")
           )

    durable_text = inspect(durable)

    refute durable_text =~ "Done"
    refute durable_text =~ "merged"
  end

  test "milestone4 persists browser evidence artifact metadata with work_run_id" do
    assert {:ok, summary} = RoadmapE2E.run("milestone4", port: 4105)

    assert_summary_contract(summary, "milestone4", "http://127.0.0.1:4105")
    assert "missing browser evidence records blocker" in summary.expected_assertions
    assert "valid evidence artifact persisted with work_run_id" in summary.expected_assertions

    [work_run_id] = summary.work_run_ids

    assert %Blocker{reason: "missing_required_evidence:browser"} =
             stored_blocker(summary.project_id, "linear_issue", "roadmap-e2e-m4")

    assert %Artifact{
             work_run_id: ^work_run_id,
             kind: "screenshot",
             metadata: %{"description" => "Roadmap evidence screenshot"}
           } = stored_artifact(summary.project_id, work_run_id)
  end

  test "dashboard evidence section shows durable milestone4 artifact metadata" do
    assert {:ok, _summary} = RoadmapE2E.run("milestone4", port: 4105)
    orchestrator_name = Module.concat(__MODULE__, :Milestone4DashboardOrchestrator)

    {:ok, _pid} =
      SnapshotOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: empty_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)

    assert html =~ "Evidence"
    assert html =~ "screenshot"
    assert html =~ "milestone4.png"
  end

  test "milestone5 seeds failed CI repair context and log fetch error variant" do
    assert {:ok, summary} = RoadmapE2E.run("milestone5", port: 4106)

    assert_summary_contract(summary, "milestone5", "http://127.0.0.1:4106")
    assert "ci_fix work run includes workflow_run and log_excerpt" in summary.expected_assertions
    assert "log_fetch_error variant persisted without crashing" in summary.expected_assertions
    assert "unknown checks do not trigger repair" in summary.expected_assertions

    assert %WorkRun{type: "ci_fix", payload: payload} =
             stored_work_run(summary.project_id, "github-ci-fix:dezet/roadmap-e2e:20:fedcba:9002")

    assert payload["workflow_run"]["id"] == 9002
    assert payload["workflow_run"]["name"] == "CI"
    assert payload["log_excerpt"] =~ "mix test failed"

    assert %WorkRun{payload: %{"log_fetch_error" => ":timeout"}} =
             stored_work_run(summary.project_id, "github-ci-fix:dezet/roadmap-e2e:21:badlog:9003")
  end

  test "dashboard work runs section shows durable milestone5 ci fix context" do
    assert {:ok, _summary} = RoadmapE2E.run("milestone5", port: 4106)
    orchestrator_name = Module.concat(__MODULE__, :Milestone5DashboardOrchestrator)

    {:ok, _pid} =
      SnapshotOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: empty_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)

    assert html =~ "Work runs"
    assert html =~ "ci_fix"
    assert html =~ "COD-501"
    assert html =~ "github-ci-fix:dezet/roadmap-e2e:20:fedcba:9002"
  end

  test "mix task supports --once and prints the scenario summary" do
    Mix.Task.reenable("harmony.roadmap_e2e")
    Application.put_env(:symphony_elixir, :work_source_fetchers, [fn -> flunk("expected mix task to install safe work sources") end])

    output =
      capture_io(fn ->
        assert :ok = RoadmapE2e.run(["milestone1", "--port", "4110", "--once"])
      end)

    assert output =~ "scenario=milestone1"
    assert output =~ "runtime_url=http://127.0.0.1:4110"
    assert output =~ "project_slug=roadmap-e2e"
    assert output =~ "dedupe_keys=linear:roadmap-e2e-issue"
    assert output =~ "external_network=false"
  end

  defp assert_summary_contract(summary, scenario, runtime_url) do
    assert %{
             scenario: ^scenario,
             runtime_url: ^runtime_url,
             project_id: project_id,
             project_slug: "roadmap-e2e",
             work_run_ids: work_run_ids,
             dedupe_keys: dedupe_keys,
             expected_assertions: expected_assertions,
             external_network?: false
           } = summary

    assert is_binary(project_id)
    assert is_list(work_run_ids)
    assert is_list(dedupe_keys)
    assert is_list(expected_assertions)
  end

  defp stored_work_run(project_id, dedupe_key) do
    Repo.get_by!(WorkRun, project_id: project_id, dedupe_key: dedupe_key)
  end

  defp stored_pr_link(project_id, pr_number) do
    Repo.get_by!(PullRequestLink, project_id: project_id, github_pr_number: pr_number)
  end

  defp stored_dedupe(project_id, key) do
    Repo.get_by!(DedupeKey, project_id: project_id, key: key)
  end

  defp stored_blocker(project_id, target_type, target_id) do
    Repo.get_by!(Blocker, project_id: project_id, target_type: target_type, target_id: target_id)
  end

  defp stored_events(project_id) do
    WorkEvent
    |> where([event], event.project_id == ^project_id)
    |> order_by([event], asc: event.type)
    |> Repo.all()
  end

  defp stored_artifact(project_id, work_run_id) do
    Repo.get_by!(Artifact, project_id: project_id, work_run_id: work_run_id)
  end

  defp stored_dedupe_count(project_id, key) do
    Repo.aggregate(from(d in DedupeKey, where: d.project_id == ^project_id and d.key == ^key), :count)
  end

  defp stored_blocker_count(project_id, target_type, target_id) do
    Repo.aggregate(
      from(b in Blocker,
        where:
          b.project_id == ^project_id and b.target_type == ^target_type and b.target_id == ^target_id and
            b.status == "open"
      ),
      :count
    )
  end

  defp empty_snapshot do
    %{
      running: [],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil,
      runtime: %{sandbox: %{}}
    }
  end

  defp start_test_endpoint(opts) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(Keyword.merge([server: false, secret_key_base: String.duplicate("s", 64)], opts))

    Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})
    :ok
  end
end
