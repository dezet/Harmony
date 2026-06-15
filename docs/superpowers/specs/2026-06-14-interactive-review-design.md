# Interactive Review Babysitting (capability a) — Design

**Status:** Draft for review

**Purpose:** Today Harmony can publish a code review **once** but cannot follow the conversation. This
feature makes Harmony read reviewer **review threads** on the change requests it opened, dispatch an
agent run to address them in code, then **reply to and resolve** each thread — a full review
conversation end-to-end. Built forge-agnostically on the `Forge` abstraction so GitHub and GitLab
reach parity from day one.

## Context — where we are

- The `Forge` behaviour can `create_review` (publish once) and `list_change_request_comments` (read
  *issue/PR-level* comments — **not** review threads tied to a diff line). It has no read/reply/resolve
  for review threads.
- Capability (d), comment-triggered review (`github_review_request_source.ex` +
  `gitlab_review_request_source.ex`), is the model: poll open CRs → match a keyword → dispatch a
  `code_review` run → a handoff publishes the result.
- Forge writes are performed by Harmony's **handoff layer** (`create_comment`/`create_review`), not by
  the agent — analogous to how Harmony never writes to the tracker directly (`SPEC.md`).
- Work sources **poll**; webhooks are refresh nudges. The GitHub webhook handles `pull_request`,
  `issue_comment`, `workflow_run` — not review events.
- The orchestrator dispatches work sources by `project.forge_type`.

## Decisions of record (from brainstorming)

1. **Scope = A2 (read + feed + reply/resolve).** v1 reads unresolved review threads, feeds them to an
   agent run that edits code, then replies to and resolves each thread. **Direction → A3** (an explicit
   "verify the feedback was addressed" judgment + re-dispatch) is documented as the next step, not
   built now.
2. **Trigger = B1 (polling work source).** A new polling source mirrors the existing review-request
   sources; reliable and works for self-host without a public URL. **→ v2: B3** adds review webhook
   events (`pull_request_review_comment` / MR note events) as a latency optimization on top of polling.
3. **Forges = C2 (GitHub + GitLab now).** The `Forge` callbacks are forge-agnostic; both adapters ship
   in v1. Accepted cost: GitHub review-thread ops need a **GraphQL** surface in `Github.Client`
   (`resolveReviewThread` has no REST equivalent); GitLab uses its REST discussions API.
4. **Agent→forge contract = Y (structured agent output, handoff writes).** The run instructs the agent
   to address each thread and emit a structured per-thread response (`{thread_id, reply, resolved}`).
   The handoff parses it and performs `reply_to_review_thread`/`resolve_review_thread` through `Forge`.
   The agent does not write to the forge directly (consistent with the handoff-writes pattern).

## Architecture

### 1. `Forge` behaviour — review-thread callbacks

```
@callback list_review_threads(creds, repo_ref, change_id) :: {:ok, [thread]} | {:error, term}
@callback reply_to_review_thread(creds, repo_ref, change_id, thread_id, body) :: :ok | {:error, term}
@callback resolve_review_thread(creds, repo_ref, change_id, thread_id) :: :ok | {:error, term}
```

`thread` is normalized:

```
%{
  id: String.t(),              # forge thread id (GraphQL node id / GitLab discussion id)
  path: String.t() | nil,      # file path the thread is anchored to
  line: integer() | nil,
  resolved: boolean(),
  author: String.t(),          # author of the first comment (the reviewer)
  comments: [%{id, author, body, created_at}],
  last_comment_at: DateTime.t()
}
```

- **`Forge.Github`** — review threads via **GraphQL**: list (`reviewThreads` with `isResolved`,
  `path`, `line`, `comments`), reply (`addPullRequestReviewThreadReply`), resolve
  (`resolveReviewThread`). A new `Github.Client.graphql/2` surface (REST stays for everything else).
- **`Forge.Gitlab`** — REST discussions: list `GET merge_requests/{iid}/discussions` (already
  threaded), reply `POST .../discussions/{id}/notes`, resolve `PUT .../discussions/{id}?resolved=true`.
- **`Forge.Memory`** — in-memory threads with a seed/record API, mirroring the existing Memory adapter,
  for work-source and handoff tests.

### 2. Review-response work source (B1)

`GithubReviewResponseSource` + `GitlabReviewResponseSource` (per-forge, thin over `Forge.adapter`,
mirroring the existing review-request sources and the orchestrator's `forge_type` dispatch). For each
**open CR Harmony opened** (one with a `pull_request_link` / `work_run` for the project), it calls
`list_review_threads` and selects threads that are:

- **unresolved**, and
- whose **newest comment is from a reviewer** (author ≠ Harmony's own identity) — so a thread whose
  last word is Harmony's own reply is skipped, and
- **not already dispatched** for that newest reviewer comment (dedupe).

Each selected CR yields one `address_review` run carrying its unresolved threads. The dedupe key is
per thread — `review-response:{owner}/{repo}:{cr}:{thread_id}:{latest_reviewer_comment_id}` — so a run
fires only when a thread gains a *new* reviewer comment since it was last handled; an unchanged thread
never re-dispatches. This is the sole "already handled" signal (no separate head-SHA bookkeeping).

### 3. `address_review` run type

`workflows/address_review_prompt.ex` builds the prompt: the CR diff plus the unresolved threads (path,
line, reviewer text), instructing the agent to (1) change code to address each thread and push
follow-up commits via its normal tooling, and (2) emit a **structured per-thread response**:

```json
{"threads": [{"thread_id": "...", "reply": "Fixed by …", "resolved": true}, …]}
```

The structured block is the run's contract with the handoff (mirrors how `code_review` runs produce
review text for `review_handoff`).

### 4. `address_review` handoff

`workflows/address_review_handoff.ex` parses the agent's structured response and, per thread:

- `Forge.reply_to_review_thread(creds, ref, cr, thread_id, reply)`;
- if `resolved`, `Forge.resolve_review_thread(creds, ref, cr, thread_id)`.

Then a Linear transition/summary consistent with the existing handoffs. Credential resolution and
forge dispatch reuse `ProjectCreds` + `Forge.adapter` exactly as the other handoffs do.

## Data flow

```
Orchestrator poll → ReviewResponseSource (forge-dispatched)
  → Forge.list_review_threads → unresolved threads whose newest comment is a reviewer's (undeduped)
  → dispatch address_review run (carries the threads)
Agent run → edits code + pushes follow-up commits + emits {threads:[{thread_id,reply,resolved}]}
Handoff → per thread: Forge.reply_to_review_thread + (resolved) Forge.resolve_review_thread
  → Linear transition
Next poll → a new reviewer comment → new dedupe key → new run (the conversation continues)
```

## Error handling

- **Partial forge write:** reply succeeds but resolve fails → log and leave the thread open; the next
  poll re-picks it (operations are idempotent by thread id). Replies are guarded against duplication by
  the dedupe key advancing only after a successful handoff.
- **Malformed agent output:** the handoff posts the replies it can parse, leaves the rest untouched,
  and raises a blocker (Linear comment) so an operator can step in — never silently drops feedback.
- **Forge read/write failures:** flow through the standard work-source/handoff block/retry paths.

## Testing

- **Forge callbacks:** `list/reply/resolve_review_thread` through `Forge.Memory`, plus `Forge.Github`
  against recorded **GraphQL** fixtures and `Forge.Gitlab` against recorded **REST discussions**
  fixtures.
- **Work source:** thread → run via Memory; dedupe; skip Harmony's own replies; only CRs Harmony
  opened; "newer than last head" selection.
- **Handoff:** structured output → the exact `reply`/`resolve` calls (recorded by Memory); partial
  failure leaves threads open + raises a blocker; malformed output handled.
- Shared contract fixtures for the normalized `thread` shape across adapters.

## Out of scope

- **A3 verification loop** — an explicit agent judgment of whether a change addressed a thread, with
  targeted re-dispatch. v1 already continues the conversation via polling (a new reviewer comment is a
  new run); A3 adds the *self-verification* judgment. Next step.
- **B3 webhook triggers** — review webhook events for lower latency. v2 optimization on top of polling.
- Forges/trackers beyond GitHub + GitLab + Linear.
- Issue/PR-level comment conversations (this feature is about diff-anchored **review threads**).

## Risks

- **GitHub GraphQL surface (C2):** review-thread ops require a new GraphQL path in `Github.Client`
  (`resolveReviewThread` has no REST form). Mitigation: scope the GraphQL client to exactly the three
  operations; cover with recorded fixtures.
- **"Addressed" is not modeled in v1:** Harmony replies and resolves based on the agent's own claim,
  not a verified check. Mitigation: this is the explicit A2/A3 boundary; resolves reflect the agent's
  structured `resolved` flag, and a reviewer re-comment re-opens the loop via polling.
- **Reacting to its own replies:** Harmony's replies are themselves thread comments. Mitigation: skip
  threads whose newest comment is authored by Harmony's identity; dedupe on the latest *reviewer*
  comment id.
