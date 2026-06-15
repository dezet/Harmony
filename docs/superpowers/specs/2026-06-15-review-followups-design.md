# Complete Interactive Review (follow-ups) — Design

**Status:** Draft for review

**Parent:** [Interactive Review Babysitting](2026-06-14-interactive-review-design.md) (capability a, v1
shipped in PR #13). This spec completes that feature: the documented follow-ups, as **one spec, three
phases**.

**Purpose:** Close the three gaps left by the review v1: (1) the "skip Harmony's own replies" filter
uses a hardcoded identity; (2) threads are resolved on the agent's bare claim with no verification and
no bounded retry (the A3 loop); (3) the trigger is polling-only (the B3 webhook latency optimization).

## Context — where we are (review v1, on main)

- `Forge` callbacks `list_review_threads/3`, `reply_to_review_thread/5`, `resolve_review_thread/4`
  (GitHub GraphQL / GitLab REST discussions / Memory).
- `Github/GitlabReviewResponseSource` poll CRs Harmony opened, select unresolved threads whose newest
  comment is a reviewer's, and emit one `address_review` run per CR. Dedupe is **per-run** (one
  `dedupe_key` from the last thread); the identity filter defaults to the literal `"harmony"`.
- `AddressReviewPrompt` demands `{"threads":[{thread_id,reply,resolved}]}`; `AddressReviewHandoff`
  parses it, replies to every thread, resolves the ones the agent marked `resolved`, then marks the
  run's dedupe key processed.
- `GithubWebhookController` (`/api/v1/github/webhook`) handles `pull_request`, `issue_comment`,
  `workflow_run` as **refresh nudges**; there is no GitLab webhook endpoint.

## Decisions of record (from brainstorming)

1. **Identity = I3** — resolve the Harmony bot login as: project config `review.bot_identity` if set →
   else forge `current_user` (whoami), cached per token → else default `"harmony"`.
2. **A3 = V3 (lightweight)** — resolve a thread only when the agent claims `resolved: true` **and** the
   thread's anchored file is in the agent's reported `files_changed`. The objective signal is the
   agent's structured `files_changed` list (not a git-diff query); a `Forge.compare_files` git-truth
   variant is noted as later hardening. Plus a **per-thread retry cap of 3**.
3. **B3 = W2 (both forges), nudge model** — webhook review events trigger a refresh; the polling source
   stays the single source of truth (no direct dispatch). GitHub adds events to the existing
   controller; GitLab gets a new controller with `X-Gitlab-Token` verification.
4. **One spec, three phases:** identity → A3 → B3.

## Architecture

### Phase 1 — Per-project bot identity (I3)

New `SymphonyElixir.Review.Identity` resolver: `resolve(project, creds, opts) :: String.t()`.
Resolution order:

1. `project.config["review"]["bot_identity"]` (non-blank string) → use it.
2. Else a token-keyed cache (ETS or a small Agent). On miss, call
   `Forge.adapter(project).current_user(creds)`; cache and return the login. On `{:error, _}`, fall
   through.
3. Else the default `"harmony"`.

New `Forge` callback `current_user(creds) :: {:ok, String.t()} | {:error, term}` — GitHub `GET /user`
→ `login`; GitLab `GET /user` → `username`; `Forge.Memory` returns a seeded login. The
`current_user` fn is injectable in the resolver for tests (mirrors the existing source/handoff seams).
Both review-response sources replace their `@default_identity` use with `Identity.resolve/3`.

### Phase 2 — A3 verification + bounded retry (V3)

**Per-thread dedupe (replaces per-run).** The dedupe key becomes per thread:
`review-response:{owner}/{repo}:{cr}:{thread_id}:{latest_reviewer_comment_id}` (already the shape; v1
only marked the *last* thread's key). The source emits a run carrying the actionable threads (as
today), but selection and marking are per thread.

**Resolve guard (the agent contract grows a field).** `AddressReviewPrompt` now also asks for the
files the agent changed:

```json
{"threads": [{"thread_id": "...", "reply": "...", "resolved": true}], "files_changed": ["lib/a.ex"]}
```

`AddressReviewHandoff`, per thread:
- always `reply_to_review_thread`;
- `resolve_review_thread` **iff** the thread is `resolved: true` **and** `thread.path ∈ files_changed`;
- a thread that is claimed-resolved-but-file-untouched, or `resolved: false`, is **left open**.

**Bounded retry.** A per-thread attempt counter keyed by `(project_id, cr, thread_id,
latest_reviewer_comment_id)` lives in the dedupe store. On each `address_review` run:
- a thread successfully resolved → mark its key **processed** (terminal; won't re-dispatch for this
  comment).
- a thread left open → increment its attempt count; if `< 3`, do **not** mark processed (the next
  poll/nudge re-dispatches it); if it reaches `3`, mark processed terminally and post a single
  "needs human review" note on the thread.

This requires a small `Storage` extension to read/increment the per-key attempt count (the store
already records dedupe status + metadata; the count lives in metadata). The source skips threads whose
key is processed (resolved or capped); it re-selects threads under the cap.

### Phase 3 — Webhook triggers (B3 / W2), nudge model

**GitHub:** add `pull_request_review` and `pull_request_review_comment` to the existing controller's
`@supported_events`. They flow through the same `append_webhook_event` + refresh path as
`workflow_run` — a nudge, no new dispatch logic.

**GitLab:** new `SymphonyElixirWeb.GitlabWebhookController` at `POST /api/v1/gitlab/webhook`. It
verifies the `X-Gitlab-Token` header against a configured secret
(`Application.get_env(:symphony_elixir, :gitlab_webhook_secret)`); on mismatch → `401`. Supported
events (the `X-Gitlab-Event` header): `Note Hook` and `Merge Request Hook` → the same
`append_webhook_event` + refresh nudge. Structure mirrors `GithubWebhookController` (event allowlist,
secret check, refresh). Both forges' review events only nudge; the polling source does all selection.

## Data flow

```
poll OR webhook-nudge → ReviewResponseSource
  identity = Review.Identity.resolve(project, creds)         # config → whoami(cache) → "harmony"
  select unresolved threads, newest comment a reviewer's, key not processed, attempts < 3
  → address_review run (threads)
agent → edits, pushes, emits {threads:[{thread_id,reply,resolved}], files_changed:[...]}
handoff (per thread):
  reply
  if resolved and thread.path in files_changed: resolve + mark key processed
  else: increment attempt; attempts==3 → post "needs human" + mark processed; else leave for re-poll
GitHub events / GitLab controller → refresh nudge → re-enters the poll path above
```

## Error handling

- **whoami failure** (Phase 1): fall back to the default identity; never block a poll on a creds-check
  call. Cache only successful lookups.
- **Malformed `files_changed`** (Phase 2): treat as empty → no thread is resolved this run (replies
  still post); the threads stay open and retry, bounded by the cap. Never resolve without the guard.
- **Partial forge write** (Phase 2): reply ok but resolve fails → leave the thread open, do not mark
  processed (idempotent re-poll), count the attempt.
- **Webhook secret mismatch / unknown event** (Phase 3): `401` for a bad GitLab token; `ignored` for an
  unsupported event (mirrors the GitHub controller). A webhook never dispatches directly, so a spoofed
  nudge at worst triggers a harmless extra poll cycle that the source's own checks gate.

## Testing

- **Identity:** config wins; whoami fallback on no config (injected `current_user`); error → default;
  cache hit avoids a second whoami; `Forge.current_user` via Memory + GitHub/GitLab fixtures.
- **A3:** resolve only when `resolved ∧ path ∈ files_changed`; claimed-but-untouched leaves open;
  `resolved:false` leaves open; attempt increments; cap at 3 → "needs human" + processed; per-thread
  dedupe (two threads on one CR tracked independently); malformed `files_changed` → empty.
- **B3:** GitHub new events nudge a refresh (extend the existing controller test); GitLab controller
  accepts a valid `X-Gitlab-Token` (200 + nudge), rejects a bad one (401), ignores unsupported events.

## Out of scope

- **Git-truth `files_changed`** via `Forge.compare_files(base_sha, head_sha)` — a later hardening of
  the V3 guard; v1 uses the agent's reported list.
- Webhook **direct dispatch** (the source remains the single source of truth).
- Per-thread reply/resolve for issue/PR-level comments (this is diff-anchored review threads only).

## Risks

- **Self-reported `files_changed`:** the guard trusts the agent's own file list, so an agent that
  both claims `resolved` and lists the file without truly fixing it still resolves. Mitigation: this is
  a strictly stronger check than v1's bare claim; the git-truth variant is the documented hardening.
- **Retry-cap bookkeeping:** the per-thread attempt count must key on the *reviewer* comment id so a
  genuinely new reviewer comment resets the budget. Mitigation: the key includes
  `latest_reviewer_comment_id`; covered by tests.
- **GitLab webhook secret:** a missing configured secret must fail closed (reject), not open.
  Mitigation: no configured secret → `401` for all GitLab webhook calls (documented; the polling path
  still works without webhooks).
