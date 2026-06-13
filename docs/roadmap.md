# Harmony Roadmap

A living view of where Harmony is and the major directions under consideration. Detailed designs
live in `docs/superpowers/specs/`, task breakdowns in `docs/superpowers/plans/`, and the decisions
behind hard-to-reverse choices in `docs/adr/`.

_Last updated: 2026-06-13._

## Where we are

Harmony is a tracker-driven daemon: it polls **Linear** for work, creates isolated per-issue
workspaces, runs **Codex** coding agents, opens **GitHub** PRs, watches CI, and hands off at
`Human Review`. Per `SPEC.md` it is a *scheduler/runner and tracker reader* — it deliberately does
not write to the tracker itself; the agent does that through its tooling.

**Recently shipped** — a full React + WebSockets operator UI, delivered in five reviewed phases
(see archived plans under `docs/superpowers/`): project-first sidebar, Overview, project workspace
(Work / Evidence / Activity / Configuration tabs), two-column run detail with a live per-run
channel, Runtime page, and operator Stop/Retry actions.

## Capability snapshot

What the backend does today, grounded in the modules that implement it:

| Capability | Status | Notes |
| --- | --- | --- |
| **(b) Pipeline/CI babysitting** — watch a PR's CI, dispatch a fix on failure | ✅ **Yes (GitHub)** | `work_sources/github_failed_ci_source.ex` detects failed workflow runs, dedupes, checks push policy (fork/protected → block), dispatches a `ci_fix` run with failure logs; `workflows/ci_fix_handoff.ex` posts a blocker comment + Linear transition. `workflow_run` webhook gives near-real-time trigger. **GitHub Actions only.** |
| **(d) Comment-triggered code review** | ✅ **Yes (GitHub)** | `work_sources/github_review_request_source.ex` polls PR comments for a keyword (default `@hreview`, per-project `review.trigger`/`review.template`), dispatches a `code_review` run; `workflows/review_handoff.ex` publishes the review. Substring match only (no labels / slash-commands); polled (~one cycle of latency). |
| **(a) Interactive PR review babysitting** — read reviewer threads, reply, resolve, verify feedback addressed | ❌ **No** | Can publish a review once (`create_pull_request_review`). Does not read incoming review threads, reply, resolve, or verify follow-up. Webhook lacks `pull_request_review_comment`. This is a **new capability**, not a refactor. |
| **(c) Multi-forge (GitHub + GitLab) + self-host** | ❌ **No** | GitHub-only and tightly coupled: ~83 `github_*` references across 19 files; `api.github.com` hardcoded in `github/client.ex` (so even GitHub Enterprise self-host is blocked today); no forge abstraction; zero GitLab code. The **tracker side already has the right pattern** (`Tracker` behaviour + Linear/Memory adapters + configurable endpoint) — a proven blueprint to copy. |
| **Project picker** — choose GitHub repo + Linear project from a list instead of typing slugs | ❌ **No (small build)** | Clients lack `list_repos`/`get_repo` (GitHub REST) and a teams/projects query (Linear GraphQL) — both small additions. UI lands in the Phase 4 Configuration tab. **Real gating factor: credentials** — tokens are global env vars today, not per-project/per-user; a picker needs a credential story to enumerate. |

## Initiatives under consideration

### 1. Forge abstraction (keystone)

**Why first:** it unblocks (c) *and* gives self-host for both forges almost for free, and it tames
the `github_*` coupling that otherwise makes every multi-forge feature a bolt-on. Lowest-risk
because it mirrors the existing, proven `Tracker` pattern.

**Approach:** introduce a `SymphonyElixir.Forge` behaviour (list repos, list PR/MR, list pipeline/CI
runs, comment, review); extract GitHub into an adapter behind it **with a configurable base URL**
(this alone enables GitHub Enterprise self-host); make project config + storage forge-agnostic
(`forge: {type, …}` replacing hardcoded `github_*`; migrate the ~83 references).

**Size:** Large — the only "project"-scale item here. The storage/config migration is the bulk;
the abstraction itself is well-understood.

### 2. GitLab support (rides on #1)

**Approach:** a GitLab REST adapter with a configurable `instance_url` (**self-hosted GitLab is then
mostly free** — the same client speaks to gitlab.com and a company instance; namespaces/groups
instead of owners), plus `GitlabMrSource` + `GitlabPipelineSource` mirroring the GitHub work sources.

**Size:** Medium-Large, but clean once #1 exists. Self-host is not a separate cost — it falls out of
a configurable base URL.

### 3. Project picker + per-project credentials

**Approach:** add `list_repos`/`get_repo` (GitHub) and a teams/projects query (Linear); a picker UI
in the Configuration tab. **Decide the credential model first** — where a project's GitHub token /
Linear key comes from (per-project secret vs. per-user OAuth). The client/UI work is days; the
credential model is the real design question.

**Size:** Small-Medium for the picker; the credential model is the gating decision.

### 4. Interactive PR-review babysitting (capability a)

**Approach:** handle `pull_request_review_comment` webhooks; read review threads and feed them to the
agent; reply to and resolve threads; a "verify the feedback was addressed in later commits" loop.
A distinct feature track, independent of the forge refactor.

**Size:** Medium — new surface area (webhook events, thread read/reply/resolve, a verification loop),
but no data-model refactor.

## Recommended sequencing

1. **Forge abstraction** — keystone; unblocks multi-forge and self-host for GitHub Enterprise too.
2. **GitLab adapter + work sources** — on top of #1; self-host via configurable `instance_url`.
3. **Picker + credential model** — can run in parallel; small UX win once credentials are settled.
4. **Interactive review babysitting** — separate feature track, schedule independently.

Highest leverage: **forge abstraction** (unlocks c + self-host). Fastest win: **picker** (if the
credential model is resolved). Biggest missing *product* capability: **interactive review (a)**.

## Cross-cutting themes

- **Self-host is a base-URL problem, not a separate feature.** Once forge clients take a configurable
  endpoint, GitHub Enterprise and self-hosted GitLab both come along — the cost is the abstraction,
  not the self-host.
- **Credentials are global today.** Pickers, multi-forge, and multi-project all eventually need a
  per-project (or per-user) credential model rather than process-wide env vars.

## Also on the radar (deferred, documented)

From the spec's "Implementation Status" section and phase plans — built deliberately small to match
what the backend can honestly serve:

- Run-stream **"logs only" filter** + a durable run transcript (no log-serving layer today). Design
  drafted as **Phase 6** (`docs/superpowers/specs/` once finalized; ADR drafts in `docs/adr/`).
- Full **attempt-history timeline** (orchestrator tracks only `restart_count`/`current_retry_attempt`).
  Also part of the Phase 6 draft.
- Per-turn token sparkline, artifact pagination, hard OS-subprocess kill on stop
  (see `docs/adr/0001-soft-stop-semantics.md` for why stop is a soft stop).
