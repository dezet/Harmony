# Frontend Phase 5 (Final): Actions, Runtime Polish, A11y, Empty States

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop/Retry-now run actions (backend + UI), real rate-limit rendering, an accessibility pass, and remaining edge polish — completing `docs/superpowers/specs/2026-06-12-frontend-uiux-design.md`.

**Architecture:** New orchestrator GenServer calls (`stop_run`, `retry_now`) reusing the existing terminate/retry-schedule machinery; POST `/runs/:identifier/stop` + `/retry` resolving identifier→issue_id via the snapshot; frontend mutations (no optimistic update — channel `status_changed` + RUN_KEY invalidation drive truth) with a confirm dialog for stop; defensive RateLimits component; targeted a11y fixes.

**Honest constraints (from the architecture pass — these define the semantics, not bugs to fix):**
- **Soft stop:** `terminate_running_issue` kills the Elixir Task; the underlying Codex OS subprocess may keep running until it exhausts context/timeout. Operator-facing meaning is "stop tracking + free the slot + mark stopped + prevent re-dispatch this cycle." The button label/UX must not promise a hard kill.
- **`"stopped"` status:** new status carried via the channel + React cache; ALSO write it durably when the running entry has `storage_work_run_id` (so a refresh keeps showing "stopped") — if that key is absent, channel/cache-only.
- **Rate-limit shape is opaque** (Codex passes it through raw; only `limit_id`/`limit_name` + bucket presence `primary`/`secondary`/`credits` are validated). The component renders defensively: progress bars when a bucket has numeric `used`+`limit`, key-value fallback otherwise, "No rate limit data" on null/empty.
- **Error code naming:** keep `run_not_found` (Phase 3 lock), not the spec's older `issue_not_found`.

**Locked decisions:**
1. Stop semantics per above; conflict handling: unknown id → `{:error, :run_not_found}` (404); stop on already-`completed` → `{:error, :already_terminal}` (409); retry-now on a non-retrying run → `{:error, :not_retrying}` (409).
2. Retry-now reuses `handle_info(:retry_issue)` via `Process.send_after(self(), {:retry_issue, issue_id, new_token}, 0)` after cancelling the existing timer (the 0ms race with the poll tick is harmless — stale token → no-op).
3. Endpoints: `POST /api/v1/runs/:identifier/stop` and `/retry` (+ `match(:*)` 405 guards) placed BEFORE the existing `get /runs/:identifier` routes; new `RunActionController` resolves identifier→issue_id by scanning snapshot running/blocked/retry_attempts (same approach as RunDetailController's live-entry lookup).
4. Frontend: `useStopRun`/`useRetryRun` mutations (sonner toast; onError surfaces `ApiError.code`; onSuccess invalidates `RUN_KEY(identifier)`); NO optimistic update. Stop requires a `ConfirmDialog` (shadcn `alert-dialog`); retry-now fires directly. Buttons enabled by status (stop when running/blocked, retry when retrying), pending spinner, `aria-label`s.
5. `useRunChannel` gains an `onConnectionError?` callback wired to `channel.join().receive("error"/"timeout")`; RunDetailPage shows a subtle inline `Alert` (role=alert) when the channel fails — also addresses the Phase 3 carry-over.
6. A11y priorities (in order): `aria-live="polite"` + `aria-label` on the RunStream list (live append announcements); channel-error Alert (role=alert, free); `aria-pressed` on stream filter buttons; `aria-label`s on Stop/Retry incl. pending; ConfirmDialog focus-trap (shadcn AlertDialog provides it); `document.title` per page (RunDetail, Runtime, Overview, workspace). DataTable sort already has `aria-sort` — no change.
7. RateLimits empty-state message moves INTO the component (accepts null). `contract.ts` gains `RateLimitBucket`/`RateLimitsPayload` (with `[key:string]: unknown` escape hatch); `StatePayload.rate_limits` narrows to `RateLimitsPayload | null`. The `state_payload.fixture.json` rate_limits placeholder becomes a realistic shape (`limit_id` + primary/secondary buckets with used/limit).
8. RunChannel auth guard (Phase 3 carry-over): there is NO auth in the app (spec: no multi-tenancy). Document this explicitly in `RunChannel.join/3` with a comment rather than adding a guard that has nothing to check — note where the guard would go if auth is introduced. (No functional change; just close the carry-over honestly.)

## Tasks

Gates per task: backend `mise exec -- mix test`; frontend `npm run test -- --run && npm run typecheck && npm run lint`. TDD. Conventional commits + AI footer.

### Task A: Orchestrator stop/retry API
Public `stop_run/1,2` + `retry_now/1,2` (whereis guard → `{:error, :run_not_found}` when the server is down) + `handle_call({:stop_run, issue_id})` and `({:retry_now, issue_id})` per Locked decisions 1-2. Stop: running/blocked → `terminate_running_issue(state, issue_id, false)`; retrying → cancel timer + `release_issue_claim`; both → add to `completed`, broadcast `publish_run_status(issue_id, identifier, "stopped", nil)`, `notify_dashboard()`, and durable `Storage.update_work_run_status(storage_work_run_id, "stopped")` when that key is present on the entry (verify the function/field names exist — if no such Storage updater exists, add a minimal one or report). Retry-now per decision 2. ExUnit tests for every branch (running/blocked/retrying/completed/unknown for stop; retrying/running/unknown for retry). Do NOT alter unrelated orchestrator logic.

### Task B: HTTP endpoints + fallback
`RunActionController` (`stop`, `retry`, `method_not_allowed`; identifier→issue_id via snapshot scan; 503 snapshot-error parity); routes before the run-detail GETs; FallbackController `:already_terminal`→409, `:not_retrying`→409 (+ @spec). Tests (FakeOrchestrator/injected orchestrator pattern from run_detail_api_test): stop on running→200 `{status:"stopped"}`; retry on retrying→200 `{status:"retrying"}`; 404 unknown; 409 already-terminal; 409 not-retrying; 405s. Trivial fixtures `stop_run_response`/`retry_run_response` optional — key-set assert inline is fine.

### Task C: Frontend mutations + contract types
`api.ts` `stopRun`/`retryRun` (POST, no body, encodeURIComponent); `contract.ts` `RateLimitBucket`/`RateLimitsPayload` + narrow `rate_limits`; `useRunActions.ts` (`useStopRun`/`useRetryRun` per decision 4, follow useProjects mutation style). api.test.ts URL + error-envelope coverage; mutation tests (onSuccess toast+invalidate, onError toast with code).

### Task D: ConfirmDialog
`npx shadcn add alert-dialog` (commit the generated ui file). `src/components/ConfirmDialog.tsx` ({open, onOpenChange, title, description, confirmLabel, onConfirm, isPending}); focus trap from AlertDialog; pending spinner on confirm. Test: open/confirm fires callback, Escape closes, pending disables+spins.

### Task E: Wire RunRail actions
RunRail uses `useStopRun`/`useRetryRun` (by `detail.identifier`); Stop opens ConfirmDialog (enabled when status running/blocked), Retry fires directly (enabled when retrying); replace the disabled placeholders; pending states; `aria-label`s ("Stop this run", "Retry this run now", pending variants). RunRail.test.tsx: stop opens dialog→confirm calls mutation; retry calls mutation; disabled-by-status.

### Task F: Channel error handling
`useRunChannel(onConnectionError?)` + `.receive("error"/"timeout")`; RunDetailPage `channelFailed` state → inline Alert; also add the RunChannel.join auth-absence comment (Locked decision 8) on the backend. Extend useRunChannel.test.ts (error callback fires); the join `.receive` chain must not break existing tests (the phoenix mock — ensure `.receive` is chainable in the mock; update the mock if needed).

### Task G: RateLimits rendering + RuntimeCard check
Replace `RateLimits.tsx` JSON dump with defensive structured rendering (decision 7): header from limit_id/limit_name; per known bucket (primary/secondary/credits) a labeled progress bar when numeric used+limit (+ reset countdown if a reset field present), else key-value rows; unknown top-level → key-value list; null/empty → "No rate limit data." Update `state_payload.fixture.json` rate_limits to a realistic shape; adjust RuntimePage (drop its now-internal empty message). RuntimeCard: confirm it renders all SandboxRuntime fields; polish only if a field is unshown. RateLimits.test.tsx: null, empty {}, stub {remaining:42}, full {limit_id, primary:{used,limit}}.

### Task H: A11y pass
RunStream: `aria-live="polite"` `aria-atomic="false"` `aria-label="Run event stream"` on the list; `aria-pressed` on filter buttons. `document.title` effects in RunDetailPage (`${identifier} — Harmony`), RuntimePage, OverviewPage, ProjectWorkspacePage (`${slug} — Harmony`). Quick audit of NeedsAttention/ActiveRuns/RecentActivity/WorkTab columns/EvidenceTab/ActivityTab for any MISSING empty state and fill it (most already have one — report which, if any, needed adding). Tests for the title effects + any new empty state.

### Task I: e2e + docs + final full gates
e2e: on a run detail for the running COD-1 entry, Stop button enabled → click → ConfirmDialog → confirm → assert a toast / status reflects stopped (mock or drive the real seeded orchestrator — the e2e harness uses a mock orchestrator; if stop_run isn't wired in the mock, either extend the mock to handle the call or assert the request fired + dialog flow; report approach). CLAUDE.md: actions, the soft-stop semantics note, rate-limit rendering, a11y notes. FINAL gates: backend full suite, frontend test+typecheck+lint+build, `mise exec -- make e2e`. This task closes the spec — confirm every Phase 1-5 deliverable is green.

## Out of scope (genuinely deferred, document in CLAUDE.md/spec)
Hard OS-subprocess kill on stop; auth/multi-tenancy; per-turn token sparkline; log streaming; artifact pagination; JsonEditor lazy-loading (build chunk-size).
