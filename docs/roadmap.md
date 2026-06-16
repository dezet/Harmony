# Harmony Roadmap

A living view of where Harmony is and the major directions under consideration. Detailed designs
live in `docs/superpowers/specs/`, task breakdowns in `docs/superpowers/plans/`, and the decisions
behind hard-to-reverse choices in `docs/adr/`.

_Last updated: 2026-06-15._

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
| **(a) Interactive CR-review babysitting** — read reviewer threads, reply, resolve, verify feedback addressed | ✅ **Yes (GitHub + GitLab)** | `Forge.{list,reply_to,resolve}_review_thread` + the `address_review` work source/run/handoff read unresolved reviewer threads, fix them in code, reply, and resolve. Per-project bot identity (config → forge whoami → default). A3 guard: resolve only threads whose anchored file the agent actually changed, with a per-thread retry cap (3) then a "needs human" note. B3: GitHub review webhook events + a GitLab webhook controller (`X-Gitlab-Token`) nudge the poller. Open hardening: git-truth `files_changed` (today the agent self-reports). |

## Initiatives under consideration

### 1. Logs / run-transcript layer + attempt-history timeline (Phase 6) — recommended next

**Why:** with capability (a) shipped, this is now the **biggest open gap** — an operator-observability
one. The agent's abilities are strong; the window into what it did is weak.

**Approach:** a run-stream **"logs only" filter** + a durable run transcript (no log-serving layer
today); a full **attempt-history timeline** (the orchestrator tracks only
`restart_count`/`current_retry_attempt`). Design drafted as Phase 6; ADR drafts in `docs/adr/`.

**Size:** Medium.

## Recommended sequencing

1. **Logs / run-transcript + attempt-history (Phase 6)** — operator observability; now the biggest
   open gap with capability (a) shipped. ADRs 0002/0003 already draft the design.

## Recently shipped — interactive review (capability a)

Read reviewer threads → fix in code → reply → resolve, across GitHub and GitLab, built on the `Forge`
abstraction. Shipped in two cuts: v1 (read + reply/resolve, polling) and the follow-ups (per-project
bot identity, the A3 resolve guard + retry cap, B3 webhook nudges for both forges). Remaining
hardening: git-truth `files_changed` instead of the agent's self-reported list.

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
