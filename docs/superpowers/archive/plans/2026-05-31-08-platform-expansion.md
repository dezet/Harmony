# Platform Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand Harmony after MVP to support multiple agent backends, multiple projects, database-backed configuration UI, inline diff comments, GitHub webhooks, and video evidence.

**Architecture:** Extract agent execution behind an `AgentBackend` behavior first, then add backend-specific adapters for Codex, Claude Code, and Pi. Expand project scheduling only after WorkRun storage is stable. Build UI against Postgres models, not YAML directly, while preserving YAML sync as an import path.

**Tech Stack:** Elixir behaviours, Codex app-server, Claude Code CLI print mode, Pi JSON event stream mode, React SPA, Phoenix JSON API, GitHub REST/webhooks, Playwright video.

---

## File Structure

- Create: `elixir/lib/symphony_elixir/agent_backend.ex`
- Create: `elixir/lib/symphony_elixir/agent_backends/codex.ex`
- Create: `elixir/lib/symphony_elixir/agent_backends/claude_code.ex`
- Create: `elixir/lib/symphony_elixir/agent_backends/pi.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/lib/symphony_elixir/codex/app_server.ex`
- Modify: `elixir/lib/symphony_elixir/project_config/schema.ex`
- Modify: `elixir/assets/src/routes/ProjectsPage.tsx`
- Modify: `elixir/assets/src/routes/ProjectFormPage.tsx`
- Modify: `elixir/lib/symphony_elixir_web/controllers/project_controller.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Create: `elixir/lib/symphony_elixir_web/controllers/github_webhook_controller.ex`
- Create: `elixir/lib/symphony_elixir/workflows/inline_review_comments.ex`
- Modify: `elixir/lib/symphony_elixir/evidence/collector.ex`
- Test: `elixir/test/symphony_elixir/agent_backend_test.exs`
- Test: `elixir/test/symphony_elixir/project_api_test.exs`
- Test: `elixir/assets/src/routes/ProjectsPage.test.tsx`
- Test: `elixir/assets/src/routes/ProjectFormPage.test.tsx`
- Test: `elixir/test/symphony_elixir/github_webhook_test.exs`
- Test: `elixir/test/symphony_elixir/inline_review_comments_test.exs`
- Test: `elixir/test/symphony_elixir/video_evidence_test.exs`

## Tasks

### Task 1: Extract AgentBackend Behavior And Codex Adapter

**Files:**
- Create: `elixir/lib/symphony_elixir/agent_backend.ex`
- Create: `elixir/lib/symphony_elixir/agent_backends/codex.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Test: `elixir/test/symphony_elixir/agent_backend_test.exs`

- [ ] **Step 1: Write backend behavior test**

```elixir
defmodule SymphonyElixir.AgentBackendTest do
  use SymphonyElixir.TestSupport

  test "codex backend delegates to app server run turn" do
    parent = self()

    run_turn = fn workspace, prompt, issue, opts ->
      send(parent, {:codex_run, workspace, prompt, issue, opts})
      {:ok, %{session_id: "thread-turn"}}
    end

    backend = SymphonyElixir.AgentBackends.Codex
    issue = %Issue{id: "issue-1", identifier: "COD-5", title: "Smoke"}

    assert {:ok, %{session_id: "thread-turn"}} =
             backend.run("/tmp/workspace", "prompt", issue, run_turn: run_turn)

    assert_received {:codex_run, "/tmp/workspace", "prompt", ^issue, _opts}
  end
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/agent_backend_test.exs
```

Expected: missing backend modules.

- [ ] **Step 3: Implement behavior and Codex adapter**

`AgentBackend` callbacks:

```elixir
@callback run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
@callback capability_check(keyword()) :: :ok | {:error, term()}
```

`AgentBackends.Codex.run/4` delegates to `Codex.AppServer.run/4`.

- [ ] **Step 4: Route AgentRunner through backend**

Add config key `agent.backend`, default `codex`. Select backend module with a small resolver:

```elixir
case backend_name do
  "codex" -> SymphonyElixir.AgentBackends.Codex
  "claude_code" -> SymphonyElixir.AgentBackends.ClaudeCode
  "pi" -> SymphonyElixir.AgentBackends.Pi
end
```

- [ ] **Step 5: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/agent_backend_test.exs test/symphony_elixir/app_server_test.exs
git add elixir/lib/symphony_elixir/agent_backend.ex elixir/lib/symphony_elixir/agent_backends elixir/lib/symphony_elixir/agent_runner.ex elixir/test/symphony_elixir/agent_backend_test.exs
git commit -m "refactor(agent): extract backend interface"
```

Expected: tests pass.

### Task 2: Add Claude Code Backend Adapter

**Files:**
- Create: `elixir/lib/symphony_elixir/agent_backends/claude_code.ex`
- Test: `elixir/test/symphony_elixir/agent_backend_test.exs`

- [ ] **Step 1: Write capability test**

```elixir
test "claude code backend reports missing executable" do
  find_executable = fn "claude" -> nil end

  assert {:error, :claude_code_not_found} =
           SymphonyElixir.AgentBackends.ClaudeCode.capability_check(find_executable: find_executable)
end
```

- [ ] **Step 2: Implement capability check and execution**

Use `System.find_executable("claude")` for capability checks. Execute work with the verified
non-interactive CLI contract: `claude --print --output-format json <prompt>` from the workspace
directory, parse `session_id` and `result`, emit an `:agent_output` update, and return command
failures as `{:claude_code_failed, exit_status, output}`.

- [ ] **Step 3: Commit**

```bash
git add elixir/lib/symphony_elixir/agent_backends/claude_code.ex elixir/test/symphony_elixir/agent_backend_test.exs
git commit -m "feat(agent): add claude code backend execution"
```

### Task 3: Add Pi Backend Adapter

**Files:**
- Create: `elixir/lib/symphony_elixir/agent_backends/pi.ex`
- Test: `elixir/test/symphony_elixir/agent_backend_test.exs`

- [ ] **Step 1: Write capability test**

```elixir
test "pi backend reports missing executable" do
  find_executable = fn "pi" -> nil end

  assert {:error, :pi_not_found} =
           SymphonyElixir.AgentBackends.Pi.capability_check(find_executable: find_executable)
end
```

- [ ] **Step 2: Implement capability check and execution**

Use `System.find_executable("pi")` for capability checks. Execute work with the documented JSON
event stream contract: `pi --mode json <prompt>` from the workspace directory, parse the session
header and final assistant text, emit an `:agent_output` update, and return command failures as
`{:pi_failed, exit_status, output}`.

- [ ] **Step 3: Commit**

```bash
git add elixir/lib/symphony_elixir/agent_backends/pi.ex elixir/test/symphony_elixir/agent_backend_test.exs
git commit -m "feat(agent): add pi backend execution"
```

### Task 4: Add Multi-Project Scheduling

**Files:**
- Modify: `elixir/lib/symphony_elixir/project_config/sync.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Test: `elixir/test/symphony_elixir/project_config_test.exs`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`

- [ ] **Step 1: Add multi-project config test**

Create two project YAML files and assert `ProjectConfig.Sync.sync_dir/1` returns two projects with distinct slugs.

- [ ] **Step 2: Add orchestrator test**

Seed two projects in storage and fake both work sources to return one candidate per project. Assert both candidates are visible in durable `work_runs` and concurrency limits still apply.

- [ ] **Step 3: Implement project iteration**

Orchestrator fetches active projects from `Storage.list_projects/0` and calls each GitHub/Linear work source per project.

- [ ] **Step 4: Commit**

```bash
git add elixir/lib/symphony_elixir/project_config/sync.ex elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/project_config_test.exs elixir/test/symphony_elixir/orchestrator_status_test.exs
git commit -m "feat(projects): schedule multiple projects"
```

### Task 5: Add Database-Backed React Project UI

**Files:**
- Modify: `elixir/assets/src/routes/ProjectsPage.tsx`
- Modify: `elixir/assets/src/routes/ProjectFormPage.tsx`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Test: `elixir/test/symphony_elixir/project_api_test.exs`
- Test: `elixir/assets/src/routes/ProjectsPage.test.tsx`
- Test: `elixir/assets/src/routes/ProjectFormPage.test.tsx`

- [ ] **Step 1: Write API and React route tests**

Test the Phoenix JSON project API for list/show/create/update. Test the React `/projects`,
`/projects/new`, and `/projects/:id/edit` routes for loaded, empty, loading, failed, create, edit,
field-error, and pending-save states.

- [ ] **Step 2: Implement React screens**

Keep UI utilitarian:

- table of projects,
- edit/new form,
- no destructive deletes in first UI version,
- validation errors from the Phoenix JSON API,
- React Query cache invalidation after create/update.

- [ ] **Step 3: Commit**

```bash
git add elixir/assets/src/routes/ProjectsPage.tsx elixir/assets/src/routes/ProjectFormPage.tsx elixir/assets/src/routes/ProjectsPage.test.tsx elixir/assets/src/routes/ProjectFormPage.test.tsx elixir/lib/symphony_elixir_web/controllers/project_controller.ex elixir/test/symphony_elixir/project_api_test.exs
git commit -m "feat(ui): add project configuration screens"
```

### Task 6: Add GitHub Webhook Receiver

**Files:**
- Create: `elixir/lib/symphony_elixir_web/controllers/github_webhook_controller.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Test: `elixir/test/symphony_elixir/github_webhook_test.exs`

- [ ] **Step 1: Write signature test**

Send a fixture payload with `X-Hub-Signature-256` and assert invalid signatures return 401 while valid signatures enqueue a refresh event.

- [ ] **Step 2: Implement webhook controller**

Support events:

- `pull_request`
- `issue_comment`
- `workflow_run`

Store raw event payload in `work_events` and request an orchestrator refresh.

- [ ] **Step 3: Commit**

```bash
git add elixir/lib/symphony_elixir_web/controllers/github_webhook_controller.ex elixir/lib/symphony_elixir_web/router.ex elixir/test/symphony_elixir/github_webhook_test.exs
git commit -m "feat(github): accept webhook refresh events"
```

### Task 7: Add Inline Review Comments

**Files:**
- Create: `elixir/lib/symphony_elixir/workflows/inline_review_comments.ex`
- Modify: `elixir/lib/symphony_elixir/github/client.ex`
- Test: `elixir/test/symphony_elixir/inline_review_comments_test.exs`

- [ ] **Step 1: Write diff-position validation tests**

Given a PR diff hunk and a proposed file/line comment, assert the module maps it to GitHub review comment `path` and `line` only when the line exists in the current diff.

- [ ] **Step 2: Implement mapper**

Reject comments that cannot be placed on current diff. Cap inline comments per review with a config value, default `10`.

- [ ] **Step 3: Commit**

```bash
git add elixir/lib/symphony_elixir/workflows/inline_review_comments.ex elixir/lib/symphony_elixir/github/client.ex elixir/test/symphony_elixir/inline_review_comments_test.exs
git commit -m "feat(review): support inline diff comments"
```

### Task 8: Add Playwright Video Proof

**Files:**
- Modify: `elixir/lib/symphony_elixir/evidence/manifest.ex`
- Modify: `elixir/lib/symphony_elixir/evidence/collector.ex`
- Test: `elixir/test/symphony_elixir/video_evidence_test.exs`

- [ ] **Step 1: Add video artifact test**

Write a manifest containing:

```json
{"frontend_changed":true,"artifacts":[{"kind":"video","path":".harmony/artifacts/walkthrough.webm","description":"Feature walkthrough"}]}
```

Assert collector persists `kind: "video"`.

- [ ] **Step 2: Allow video kind**

Add `video` to allowed artifact kinds and require a non-empty description for videos.

- [ ] **Step 3: Commit**

```bash
git add elixir/lib/symphony_elixir/evidence/manifest.ex elixir/lib/symphony_elixir/evidence/collector.ex elixir/test/symphony_elixir/video_evidence_test.exs
git commit -m "feat(evidence): support playwright video proof"
```

### Task 9: Validate Platform Expansion

- [ ] **Step 1: Run targeted tests**

```bash
cd elixir
mix test test/symphony_elixir/agent_backend_test.exs test/symphony_elixir/project_api_test.exs test/symphony_elixir/github_webhook_test.exs test/symphony_elixir/inline_review_comments_test.exs test/symphony_elixir/video_evidence_test.exs
cd assets && npm test -- ProjectsPage.test.tsx ProjectFormPage.test.tsx --run
```

Expected: all pass.

- [ ] **Step 2: Run full gate**

```bash
cd elixir
make all
```

Expected: full gate exits 0.
