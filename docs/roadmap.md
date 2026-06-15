# Harmony Roadmap

A living view of where Harmony is and the major directions under consideration. Detailed designs
live in `docs/superpowers/specs/`, task breakdowns in `docs/superpowers/plans/`, and the decisions
behind hard-to-reverse choices in `docs/adr/`.

_Last updated: 2026-06-14._

## Where we are

Harmony is a tracker-driven daemon: it polls **Linear** for work, creates isolated per-issue
workspaces, runs **Codex** coding agents, opens **GitHub or GitLab** change requests, watches CI, and
hands off at `Human Review`. Per `SPEC.md` it is a *scheduler/runner and tracker reader* — it
deliberately does not write to the tracker itself; the agent does that through its tooling.

**Recently shipped — the multi-forge platform arc (Phases 1–4 + picker).** Harmony is no longer
GitHub-only:

- **Forge abstraction** (`SymphonyElixir.Forge` behaviour + GitHub/GitLab/Memory adapters), mirroring
  the proven `Tracker` pattern; storage and project config are forge-agnostic (`forge_type` + generic
  `forge_*` columns, the ~83 `github_*` references migrated).
- **GitLab support** (`Forge.Gitlab` with configurable `instance_url`, `GitlabMrSource` +
  `GitlabPipelineSource`) and **self-host** for both forges via a configurable base URL.
- **Per-project encrypted credentials** (Cloak AES-256-GCM, `CLOAK_KEY` fail-fast, write-only secret
  API) resolved per-call with a global-env fallback.
- **Project picker** — repo and Linear-project choosers in the Configuration tab, replacing free-text
  slugs, validated against the live forge/tracker with the project's token.

Before that, a full React + WebSockets operator UI was delivered in five reviewed phases:
project-first sidebar, Overview, project workspace (Work / Evidence / Activity / Configuration tabs),
two-column run detail with a live per-run channel, Runtime page, and operator Stop/Retry actions.

## Capability snapshot

What the backend does today, grounded in the modules that implement it:

| Capability | Status | Notes |
| --- | --- | --- |
| **(c) Multi-forge (GitHub + GitLab) + self-host** | ✅ **Yes** | `Forge` behaviour + `Forge.{Github,Gitlab,Memory}` adapters; forge-agnostic storage/config; configurable base URL / `instance_url` (GitHub Enterprise + self-hosted GitLab); per-project encrypted credentials with env fallback. |
| **(b) Pipeline/CI babysitting** — watch a CR's CI, dispatch a fix on failure | ✅ **Yes (GitHub + GitLab)** | `work_sources/github_failed_ci_source.ex` (Actions) and `work_sources/gitlab_pipeline_source.ex` (pipelines) detect failures, dedupe, check push policy (fork/protected → block), dispatch a `ci_fix` run with logs; `workflows/ci_fix_handoff.ex` posts a blocker + Linear transition. |
| **(d) Comment-triggered code review** | ✅ **Yes (GitHub + GitLab)** | `github_review_request_source.ex` / `gitlab_review_request_source.ex` poll PR/MR comments for a keyword (default `@hreview`, per-project `review.trigger`/`review.template`), dispatch a `code_review` run; `workflows/review_handoff.ex` publishes it. Substring match; polled (~one cycle of latency). |
| **Project picker** — choose repo + Linear project from a list | ✅ **Yes** | `Forge.list_repositories`/`get_repository` + `Tracker.list_projects` (Linear GraphQL); stateless token-in-body endpoints; searchable comboboxes in the Configuration tab. |
| **(a) Interactive CR-review babysitting** — read reviewer threads, reply, resolve, verify feedback addressed | ❌ **No** | Can publish a review once (`create_review`). Does not read incoming review threads, reply, resolve, or verify follow-up. Webhooks lack the review-comment events. This is a **new capability**, not a refactor. |

## Initiatives under consideration

### 1. Interactive CR-review babysitting (capability a) — recommended next

**Why next:** with the multi-forge platform shipped, this is the **biggest missing product
capability** — and the one the rest of the infrastructure was building toward. Today Harmony can
publish a review once; it cannot follow a conversation.

**Approach:** read review/discussion threads and feed them to the agent; reply to and resolve
threads; a "verify the feedback was addressed in later commits" loop. Trigger via the forge's
review-comment webhook events (GitHub `pull_request_review_comment`, GitLab MR note events) with a
polled fallback.

**Forge-agnostic from the start.** Unlike when this was first scoped, the `Forge` behaviour now
exists — so design the thread read/reply/resolve operations as new `Forge` callbacks with a common
normalized shape (GitHub review threads ↔ GitLab MR discussion threads), rather than GitHub-only with
a GitLab bolt-on later. New surface area: review-comment webhooks, thread read/reply/resolve, a
verification loop. No data-model refactor.

**Size:** Medium.

### 2. Logs / run-transcript layer + attempt-history timeline (Phase 6)

**Why:** an operator-observability gap, not a missing agent capability — schedule after (a).

**Approach:** a run-stream **"logs only" filter** + a durable run transcript (no log-serving layer
today); a full **attempt-history timeline** (the orchestrator tracks only
`restart_count`/`current_retry_attempt`). Design drafted as Phase 6; ADR drafts in `docs/adr/`.

**Size:** Medium.

## Recommended sequencing

1. **Interactive review babysitting (a)** — biggest missing product capability; design it
   forge-agnostic on top of the new `Forge` abstraction.
2. **Logs / run-transcript + attempt-history (Phase 6)** — operator observability; follows (a).

## Cross-cutting themes

- **Self-host is a base-URL problem, solved.** Forge clients take a configurable endpoint, so GitHub
  Enterprise and self-hosted GitLab both come along — the cost was the abstraction, now paid.
- **Credentials are per-project, solved.** Per-project encrypted secrets (Cloak) replaced
  process-wide env vars, with env as a fallback. Out of scope by decision: per-user OAuth / a user
  model.

## Also on the radar (deferred, documented)

Built deliberately small to match what the backend can honestly serve:

- Run-stream **"logs only" filter** + durable run transcript — part of the Phase 6 work above.
- Full **attempt-history timeline** — part of the Phase 6 work above.
- Per-turn token sparkline, artifact pagination, hard OS-subprocess kill on stop (see
  `docs/adr/0001-soft-stop-semantics.md` for why stop is a soft stop).
