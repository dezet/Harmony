# Browser Evidence MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Require runtime-level browser evidence before frontend-changing work can hand off to Human Review.

**Architecture:** Add an `Evidence` context that detects frontend-relevant changes, checks configured browser tooling capability, reads a workspace evidence manifest, persists artifact metadata, and blocks handoff when required evidence is missing. MVP accepts screenshot, trace, or report artifacts; Playwright video proof is introduced in the platform expansion plan.

**Tech Stack:** Elixir, existing workspace filesystem, Postgres artifacts table, Codex app-server runtime, Playwright/Chrome MCP configuration checks.

---

## File Structure

- Create: `elixir/lib/symphony_elixir/evidence/policy.ex`
- Create: `elixir/lib/symphony_elixir/evidence/manifest.ex`
- Create: `elixir/lib/symphony_elixir/evidence/capability.ex`
- Create: `elixir/lib/symphony_elixir/evidence/collector.ex`
- Modify: `elixir/lib/symphony_elixir/storage.ex`
- Modify: `elixir/lib/symphony_elixir/runtime_policy/handoff.ex`
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Test: `elixir/test/symphony_elixir/evidence_test.exs`
- Test: `elixir/test/symphony_elixir/extensions_test.exs`

## Evidence Manifest Contract

Agents write `.harmony/evidence.json` in the workspace:

```json
{
  "frontend_changed": true,
  "scenario": "Open the edited page and verify the changed interaction",
  "artifacts": [
    {
      "kind": "screenshot",
      "path": ".harmony/artifacts/frontend-check.png",
      "description": "Verified the edited view renders without overlap"
    }
  ]
}
```

Allowed MVP artifact kinds:

- `screenshot`
- `trace`
- `report`

## Tasks

### Task 1: Detect Frontend Changes

**Files:**
- Create: `elixir/lib/symphony_elixir/evidence/policy.ex`
- Test: `elixir/test/symphony_elixir/evidence_test.exs`

- [ ] **Step 1: Write policy tests**

```elixir
defmodule SymphonyElixir.EvidenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Evidence.Policy

  test "requires browser evidence for frontend paths" do
    changed = ["assets/js/app.js", "lib/my_app_web/live/page_live.ex"]
    assert Policy.requires_browser_evidence?(changed, frontend_paths: ["assets/", "lib/my_app_web/"])
  end

  test "does not require browser evidence for backend-only paths" do
    changed = ["lib/my_app/accounts.ex", "test/my_app/accounts_test.exs"]
    refute Policy.requires_browser_evidence?(changed, frontend_paths: ["assets/", "lib/my_app_web/"])
  end
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/evidence_test.exs
```

Expected: missing `Evidence.Policy`.

- [ ] **Step 3: Implement policy**

```elixir
defmodule SymphonyElixir.Evidence.Policy do
  @moduledoc """
  Determines whether a work run requires browser evidence.
  """

  @default_frontend_paths ["assets/", "priv/static/", "lib/", "web/", "src/"]

  @spec requires_browser_evidence?([String.t()], keyword()) :: boolean()
  def requires_browser_evidence?(changed_paths, opts \\ []) when is_list(changed_paths) do
    prefixes = Keyword.get(opts, :frontend_paths, @default_frontend_paths)

    Enum.any?(changed_paths, fn path ->
      is_binary(path) and Enum.any?(prefixes, &String.starts_with?(path, &1))
    end)
  end
end
```

- [ ] **Step 4: Run test and commit**

```bash
cd elixir
mix test test/symphony_elixir/evidence_test.exs
git add elixir/lib/symphony_elixir/evidence/policy.ex elixir/test/symphony_elixir/evidence_test.exs
git commit -m "feat(evidence): detect frontend evidence requirement"
```

Expected: tests pass.

### Task 2: Parse Workspace Evidence Manifest

**Files:**
- Create: `elixir/lib/symphony_elixir/evidence/manifest.ex`
- Test: `elixir/test/symphony_elixir/evidence_test.exs`

- [ ] **Step 1: Add manifest tests**

```elixir
test "reads evidence manifest and resolves artifact paths under workspace" do
  workspace = Path.join(System.tmp_dir!(), "harmony-evidence-#{System.unique_integer([:positive])}")
  File.mkdir_p!(Path.join(workspace, ".harmony/artifacts"))
  File.write!(Path.join(workspace, ".harmony/artifacts/frontend-check.png"), "png")
  File.write!(Path.join(workspace, ".harmony/evidence.json"), ~s({
    "frontend_changed": true,
    "scenario": "Open changed screen",
    "artifacts": [{"kind": "screenshot", "path": ".harmony/artifacts/frontend-check.png", "description": "screen"}]
  }))

  assert {:ok, manifest} = SymphonyElixir.Evidence.Manifest.read(workspace)
  assert manifest.frontend_changed == true
  assert [%{kind: "screenshot", path: path}] = manifest.artifacts
  assert path == Path.join(workspace, ".harmony/artifacts/frontend-check.png")
after
  File.rm_rf(workspace)
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/evidence_test.exs
```

Expected: missing manifest module.

- [ ] **Step 3: Implement manifest parser**

Create `Evidence.Manifest.read/1` that:

- looks for `.harmony/evidence.json`,
- parses JSON with Jason,
- rejects artifact kinds outside `["screenshot", "trace", "report"]`,
- expands artifact paths under workspace,
- rejects paths escaping the workspace.

Return struct:

```elixir
%{
  frontend_changed: boolean(),
  scenario: String.t() | nil,
  artifacts: [%{kind: String.t(), path: Path.t(), description: String.t() | nil}]
}
```

- [ ] **Step 4: Run test and commit**

```bash
cd elixir
mix test test/symphony_elixir/evidence_test.exs
git add elixir/lib/symphony_elixir/evidence/manifest.ex elixir/test/symphony_elixir/evidence_test.exs
git commit -m "feat(evidence): parse browser evidence manifest"
```

Expected: tests pass.

### Task 3: Add Capability Check For Browser MCP Runtime

**Files:**
- Create: `elixir/lib/symphony_elixir/evidence/capability.ex`
- Test: `elixir/test/symphony_elixir/evidence_test.exs`

- [ ] **Step 1: Add capability tests**

```elixir
test "reports browser evidence capability from configured commands" do
  probe = fn "playwright-mcp" -> {:ok, "ok"} end

  assert {:ok, %{playwright_mcp: true}} =
           SymphonyElixir.Evidence.Capability.check(probe_command: probe)
end

test "reports missing browser tooling as unavailable" do
  probe = fn "playwright-mcp" -> {:error, :enoent} end

  assert {:error, {:browser_evidence_unavailable, [:playwright_mcp]}} =
           SymphonyElixir.Evidence.Capability.check(probe_command: probe)
end
```

- [ ] **Step 2: Run failing tests**

```bash
cd elixir
mix test test/symphony_elixir/evidence_test.exs
```

Expected: missing capability module.

- [ ] **Step 3: Implement capability check**

Create `Evidence.Capability.check/1` that probes configured command names. In MVP, probe `"playwright-mcp"` because Playwright is the desired evidence path. The default probe should use `System.find_executable/1`.

- [ ] **Step 4: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/evidence_test.exs
git add elixir/lib/symphony_elixir/evidence/capability.ex elixir/test/symphony_elixir/evidence_test.exs
git commit -m "feat(evidence): check browser tooling capability"
```

Expected: tests pass.

### Task 4: Persist Evidence Artifacts

**Files:**
- Create: `elixir/lib/symphony_elixir/evidence/collector.ex`
- Modify: `elixir/lib/symphony_elixir/storage.ex`
- Test: `elixir/test/symphony_elixir/evidence_test.exs`

- [ ] **Step 1: Add collector test**

```elixir
test "collector persists manifest artifacts" do
  {:ok, project} =
    SymphonyElixir.Storage.upsert_project(%{
      slug: "portal",
      github_owner: "dezet",
      github_repo: "portal",
      github_base_branch: "develop",
      linear_project_slug: "portal-linear",
      linear_human_review_state: "Human Review",
      config_version: 1,
      config: %{}
    })

  workspace = Path.join(System.tmp_dir!(), "harmony-evidence-store-#{System.unique_integer([:positive])}")
  File.mkdir_p!(Path.join(workspace, ".harmony/artifacts"))
  artifact_path = Path.join(workspace, ".harmony/artifacts/frontend-check.txt")
  File.write!(artifact_path, "ok")
  File.write!(Path.join(workspace, ".harmony/evidence.json"), ~s({"frontend_changed":true,"artifacts":[{"kind":"report","path":".harmony/artifacts/frontend-check.txt","description":"ok"}]}))

  assert {:ok, [%SymphonyElixir.Storage.Artifact{kind: "report"}]} =
           SymphonyElixir.Evidence.Collector.collect(project.id, nil, workspace)
after
  File.rm_rf(workspace)
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/evidence_test.exs
```

Expected: missing collector or storage function.

- [ ] **Step 3: Implement collector and storage helper**

Add `Storage.create_artifact/1`. Implement `Collector.collect/3` to parse manifest and insert each artifact with metadata containing scenario and description.

- [ ] **Step 4: Run test and commit**

```bash
cd elixir
mix test test/symphony_elixir/evidence_test.exs
git add elixir/lib/symphony_elixir/evidence/collector.ex elixir/lib/symphony_elixir/storage.ex elixir/test/symphony_elixir/evidence_test.exs
git commit -m "feat(evidence): persist browser artifacts"
```

Expected: tests pass.

### Task 5: Gate Human Review Handoff On Required Evidence

**Files:**
- Modify: `elixir/lib/symphony_elixir/runtime_policy/handoff.ex`
- Test: `elixir/test/symphony_elixir/evidence_test.exs`

- [ ] **Step 1: Add handoff blocking test**

```elixir
test "handoff blocks when browser evidence is required and missing" do
  run = %SymphonyElixir.WorkRun{id: "run-1", required_evidence: ["browser"], payload: %{}}

  assert {:error, {:missing_required_evidence, ["browser"]}} =
           SymphonyElixir.RuntimePolicy.Handoff.verify_required_evidence(run, [])
end

test "handoff passes when browser evidence artifact exists" do
  run = %SymphonyElixir.WorkRun{id: "run-1", required_evidence: ["browser"], payload: %{}}
  artifacts = [%{kind: "screenshot", path: "/tmp/screen.png"}]

  assert :ok = SymphonyElixir.RuntimePolicy.Handoff.verify_required_evidence(run, artifacts)
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/evidence_test.exs
```

Expected: missing `verify_required_evidence/2`.

- [ ] **Step 3: Implement verification**

In `RuntimePolicy.Handoff`, add:

```elixir
@spec verify_required_evidence(map(), [map()]) :: :ok | {:error, term()}
def verify_required_evidence(run, artifacts) do
  required = Map.get(run, :required_evidence, [])

  missing =
    required
    |> Enum.reject(fn
      "browser" -> Enum.any?(artifacts, &(Map.get(&1, :kind) in ["screenshot", "trace", "report"]))
      _ -> false
    end)

  if missing == [], do: :ok, else: {:error, {:missing_required_evidence, missing}}
end
```

- [ ] **Step 4: Wire into handoff path**

Before moving Linear issue to `Human Review`, collect artifacts and call `verify_required_evidence/2`. If missing, record a blocker and do not move the issue.

- [ ] **Step 5: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/evidence_test.exs test/symphony_elixir/runtime_policy_test.exs
git add elixir/lib/symphony_elixir/runtime_policy/handoff.ex elixir/test/symphony_elixir/evidence_test.exs
git commit -m "feat(evidence): require browser artifacts for handoff"
```

Expected: tests pass.

### Task 6: Surface Evidence In API And Dashboard

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Test: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: Add presenter test**

Extend existing state payload tests to include:

```elixir
assert state_payload["artifacts"] == [
  %{"kind" => "screenshot", "path" => "/var/lib/harmony/artifacts/run-1/screen.png"}
]
```

Use the same static orchestrator pattern already present in `extensions_test.exs`.

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/extensions_test.exs
```

Expected: payload lacks artifacts.

- [ ] **Step 3: Add artifacts projection**

Update presenter to include artifacts from snapshot or storage query. Keep API shape:

```elixir
artifacts: Enum.map(Map.get(snapshot, :artifacts, []), &artifact_payload/1)
```

Add dashboard section `Evidence` listing kind and path.

- [ ] **Step 4: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/extensions_test.exs
git add elixir/lib/symphony_elixir_web/presenter.ex elixir/lib/symphony_elixir_web/live/dashboard_live.ex elixir/test/symphony_elixir/extensions_test.exs
git commit -m "feat(evidence): expose browser artifacts"
```

Expected: tests pass.

### Task 7: Validate Browser Evidence MVP

- [ ] **Step 1: Run evidence tests**

```bash
cd elixir
mix test test/symphony_elixir/evidence_test.exs test/symphony_elixir/extensions_test.exs
```

Expected: all pass.

- [ ] **Step 2: Manual frontend proof run**

Use a disposable PR that changes a frontend path and instruct the agent to produce `.harmony/evidence.json`.

Expected:

- missing manifest blocks Human Review,
- valid manifest with screenshot/report allows Human Review,
- artifact metadata appears in `/api/v1/state`,
- dashboard renders artifact path.

