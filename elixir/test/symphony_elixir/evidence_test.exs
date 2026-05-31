defmodule SymphonyElixir.EvidenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Evidence.{Capability, Collector, Manifest, Policy}
  alias SymphonyElixir.RuntimePolicy.Handoff
  alias SymphonyElixir.Storage.Artifact
  alias SymphonyElixir.WorkRun

  test "requires browser evidence for frontend paths" do
    changed = ["assets/js/app.js", "lib/my_app_web/live/page_live.ex"]

    assert Policy.requires_browser_evidence?(changed,
             frontend_paths: ["assets/", "lib/my_app_web/"]
           )
  end

  test "does not require browser evidence for backend-only paths" do
    changed = ["lib/my_app/accounts.ex", "test/my_app/accounts_test.exs"]

    refute Policy.requires_browser_evidence?(changed,
             frontend_paths: ["assets/", "lib/my_app_web/"]
           )
  end

  test "reads evidence manifest and resolves artifact paths under workspace" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "harmony-evidence-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
      )

    try do
      File.mkdir_p!(Path.join(workspace, ".harmony/artifacts"))
      File.write!(Path.join(workspace, ".harmony/artifacts/frontend-check.png"), "png")

      File.write!(Path.join(workspace, ".harmony/evidence.json"), ~s({
        "frontend_changed": true,
        "scenario": "Open changed screen",
        "artifacts": [{"kind": "screenshot", "path": ".harmony/artifacts/frontend-check.png", "description": "screen"}]
      }))

      assert {:ok, manifest} = Manifest.read(workspace)
      assert manifest.frontend_changed == true
      assert [%{kind: "screenshot", path: path, description: "screen"}] = manifest.artifacts
      assert path == Path.join(workspace, ".harmony/artifacts/frontend-check.png")
    after
      File.rm_rf(workspace)
    end
  end

  test "reports browser evidence capability from configured commands" do
    probe = fn "playwright-mcp" -> {:ok, "ok"} end

    assert {:ok, %{playwright_mcp: true}} =
             Capability.check(probe_command: probe)
  end

  test "reports missing browser tooling as unavailable" do
    probe = fn "playwright-mcp" -> {:error, :enoent} end

    assert {:error, {:browser_evidence_unavailable, [:playwright_mcp]}} =
             Capability.check(probe_command: probe)
  end

  test "collector persists manifest artifacts" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "harmony-evidence-store-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
      )

    parent = self()

    persist_artifact = fn attrs ->
      send(parent, {:artifact_attrs, attrs})
      {:ok, struct(Artifact, attrs)}
    end

    try do
      File.mkdir_p!(Path.join(workspace, ".harmony/artifacts"))
      artifact_path = Path.join(workspace, ".harmony/artifacts/frontend-check.txt")
      File.write!(artifact_path, "ok")

      File.write!(
        Path.join(workspace, ".harmony/evidence.json"),
        ~s({"frontend_changed":true,"scenario":"Open changed screen","artifacts":[{"kind":"report","path":".harmony/artifacts/frontend-check.txt","description":"ok"}]})
      )

      assert {:ok, [%Artifact{kind: "report"}]} =
               Collector.collect("project-1", nil, workspace, persist_artifact: persist_artifact)

      assert_received {:artifact_attrs,
                       %{
                         project_id: "project-1",
                         work_run_id: nil,
                         kind: "report",
                         path: ^artifact_path,
                         metadata: %{"description" => "ok", "scenario" => "Open changed screen"}
                       }}
    after
      File.rm_rf(workspace)
    end
  end

  test "handoff blocks when browser evidence is required and missing" do
    run = %WorkRun{id: "run-1", required_evidence: ["browser"], payload: %{}}

    assert {:error, {:missing_required_evidence, ["browser"]}} =
             Handoff.verify_required_evidence(run, [])
  end

  test "handoff passes when browser evidence artifact exists" do
    run = %WorkRun{id: "run-1", required_evidence: ["browser"], payload: %{}}
    artifacts = [%{kind: "screenshot", path: "/tmp/screen.png"}]

    assert :ok = Handoff.verify_required_evidence(run, artifacts)
  end

  test "move to human review does not update issue when required evidence is missing" do
    parent = self()

    tracker = fn issue_id, state_name ->
      send(parent, {:state_update, issue_id, state_name})
      :ok
    end

    assert {:error, {:missing_required_evidence, ["browser"]}} =
             Handoff.move_to_human_review(
               %{linear_issue_id: "issue-1", required_evidence: ["browser"]},
               "Human Review",
               artifacts: [],
               tracker_update: tracker
             )

    refute_received {:state_update, _issue_id, _state_name}
  end
end
