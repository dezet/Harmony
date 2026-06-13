# GitLab Adapter (Multi-Forge Phase 4) — Design

**Status:** Draft for review

**Parent:** `docs/superpowers/specs/2026-06-13-multi-forge-platform-design.md` (Phase 4 milestone,
sharpened here). Builds on the merged Phase 1 foundation (`Forge` behaviour + `Forge.Github` +
forge-agnostic storage), PR #8.

**Purpose:** Add full GitLab support — gitlab.com and self-hosted — at **feature parity with GitHub**:
MR observation, pipeline (CI) repair, and `@hreview` comment-triggered review. Self-hosted GitLab
comes for free via a configurable `instance_url` (the `forge_base_url` column already exists).

## Context — grounded in the realized Phase 1 architecture

Phase 1 shipped and its post-implementation notes
(`docs/superpowers/plans/2026-06-13-multi-forge-platform.md`, "realized-architecture notes") govern
this phase:

- **Work sources are forge-specific by design, not forge-neutral.** GitHub work sources read through
  `Github.Client` because `RepoPolicy` (fork detection via `head_repo_full_name`/`base_repo_full_name`)
  and `LinkResolver` (`title`/`body`) need richer PR fields than the slim normalized `change_request`
  shape. GitLab therefore gets its **own** `GitlabMrSource` / `GitlabPipelineSource` /
  `GitlabReviewRequestSource` modules — it does not reuse the GitHub sources.
- **The `Forge` behaviour's production role** is the genuinely shared ops: `create_comment` /
  `create_review` (handoffs) and `list_repositories` / `get_repository` (picker, Phase 3). The
  `list_change_requests` / `list_pipeline_runs` / `get_pipeline_logs` callbacks are the **GitLab
  contract surface** — each adapter must implement them. **Correction discovered during planning:**
  the handoffs currently call `Forge.Github.create_comment` / `create_review` *directly* (not via
  `Forge.adapter/1`), and `ProjectCreds.creds/2` hardcodes `GITHUB_TOKEN`. This phase makes both
  forge-neutral so a `gitlab` project's handoff posts to GitLab with a GitLab token.
- **Work-source fetchers are injected via `Application.get_env`;** production defaults hardcode the
  `Github*` sources. This phase adds a `forge_type` dispatch wrapper that selects `Gitlab*` sources
  when `project.forge_type == "gitlab"`.
- **`list_change_request_comments` does not exist yet** on the behaviour. The GitHub review-request
  source still calls `Github.Client.list_issue_comments` directly. This phase adds the callback to the
  behaviour and **both** adapters, retiring that Phase 1 follow-up.

Credentials remain **global env vars** for this phase (`GITLAB_TOKEN`, mirroring today's
`GITHUB_TOKEN`); `creds_for/1` already falls back to env. Per-project encrypted credentials (Phase 2)
and the repo/project picker (Phase 3) are explicitly **out of scope here** — the user's chosen
sequence is GitLab → picker+credentials → interactive review → logs.

## Scope decision

- **Full parity** across all three GitHub work-source capabilities: MR observation, pipeline/CI
  repair, and `@hreview` comment trigger.
- **Polling first.** Capability parity is delivered through the orchestrator's existing poll loop.
  GitLab webhooks (near-real-time pipeline/note events) are a documented **fast-follow**, not part of
  this phase — they optimize latency, not capability.

## Architecture

### New modules (each mirrors a GitHub counterpart)

| New module | Mirrors | Responsibility |
| --- | --- | --- |
| `lib/symphony_elixir/forge/gitlab.ex` (`Forge.Gitlab`) | `forge/github.ex` | Implements all `Forge` callbacks; normalizes GitLab shapes to the common ones |
| `lib/symphony_elixir/gitlab/client.ex` (`Gitlab.Client`) | `github/client.ex` | GitLab REST v4 over `Req`; configurable `instance_url`; `request_fun`/`token` injection for tests |
| `lib/symphony_elixir/gitlab/merge_request.ex` | `github/pull_request.ex` | Rich MR struct for the MR work source |
| `lib/symphony_elixir/gitlab/pipeline.ex` | `github/workflow_run.ex` | Rich pipeline/job struct for the pipeline work source |
| `lib/symphony_elixir/work_sources/gitlab_mr_source.ex` | `github_pr_source.ex` | Observe open MRs → dispatch |
| `lib/symphony_elixir/work_sources/gitlab_pipeline_source.ex` | `github_failed_ci_source.ex` | Failed pipeline → CI-fix dispatch |
| `lib/symphony_elixir/work_sources/gitlab_review_request_source.ex` | `github_review_request_source.ex` | `@hreview` in MR notes → review dispatch |

### GitLab → GitHub mapping (absorbed by the normalized shapes)

- **Project path:** GitLab uses a URL-encoded `namespace/group/repo` path as the API `:id`
  (`GET /api/v4/projects/{url-encoded path}`). `forge_owner` stores the namespace/group path;
  `forge_repo` the project name; the client URL-encodes `"#{owner}/#{repo}"`.
- **Identifiers:** MRs are addressed by per-project `iid` (not the global `id`); pipelines by `id`.
  Normalize `iid` → the common `change_request.number`. Carry `iid` (and `project_id` where the API
  needs it) on the rich `MergeRequest` struct for work-source calls.
- **CI:** GitLab `pipelines` + `jobs` replace GitHub workflow runs. `get_pipeline_logs` concatenates
  failed-job **traces** (`GET /projects/:id/jobs/:job_id/trace`) as the error payload, mirroring
  `get_workflow_run_logs`.
- **Comments / review:** GitLab **notes** replace issue comments (`POST .../merge_requests/:iid/notes`).
  Review parity uses an MR note (an MR-level approval is a deliberate non-goal for parity here).

### Normalized shapes (unchanged — already defined by `Forge`)

- `repo: %{owner, name, default_branch, url}`
- `change_request: %{number, head_sha, head_ref, base_ref, url}` (GitLab: `number` ← `iid`)
- `pipeline_run: %{id, name, status, conclusion, head_sha}` (GitLab: `conclusion` ← pipeline status
  mapped onto the GitHub-style success/failure vocabulary the orchestrator already understands)

### Behaviour extension

Add to `Forge` and **both** adapters:

```
@callback list_change_request_comments(creds, repo_ref, term()) :: {:ok, [map()]} | {:error, term()}
```

- `Forge.Github`: delegate to `Github.Client.list_issue_comments`, normalize to `%{id, body, user}`.
- `Forge.Gitlab`: `GET .../merge_requests/:iid/notes`, normalize to the same shape.
- Repoint `GithubReviewRequestSource` from the direct `Github.Client.list_issue_comments` call onto
  `Forge.adapter(project).list_change_request_comments/3`, so the trigger-scan path is forge-neutral.

### Dispatch wiring

The orchestrator's work-source fetchers are injected via `Application.get_env`, defaulting to the
`Github*` modules. Add a `forge_type`-aware selector (a small wrapper) that resolves to the `Gitlab*`
sources when `project.forge_type == "gitlab"`, else the `Github*` sources. This is the only
orchestrator change; the dispatch/dedupe/blocker/handoff machinery downstream is forge-agnostic
already.

## Data flow

```
Orchestrator poll → forge_type selector → Gitlab{Mr,Pipeline,ReviewRequest}Source
  → Gitlab.Client (instance_url + GITLAB_TOKEN) → normalized change_request / pipeline_run shapes
  → run dispatch (unchanged) → handoff via Forge.adapter(project).create_comment/create_review
```

## Credentials & config

- **Token:** global `GITLAB_TOKEN` env, resolved by the existing `creds_for/1` env fallback. No new
  storage.
- **Project config:** existing `forge_type: "gitlab"`, `forge_owner` (namespace/group path),
  `forge_repo`, `forge_base_url` (the GitLab `instance_url`; `nil`/default = gitlab.com). **No new
  migration** — Phase 1 columns suffice. `project_config/schema.ex` already parses the `forge:`
  section; confirm `type: "gitlab"` round-trips.

## Security

- Self-host is a base-URL concern: `forge_base_url` drives `Gitlab.Client`'s API root; no hardcoded
  host. The same adapter serves gitlab.com and a company instance.
- Token read from env only; never logged, never echoed.
- (Webhook signature verification lands with the deferred webhook follow-up, not here.)

## Testing

- **`Forge.Gitlab`:** unit tests against recorded GitLab REST v4 fixtures via the client's
  `request_fun` injection; assert normalization to the common shapes and `instance_url` honoring.
- **Behaviour callback:** `list_change_request_comments` round-trip on both adapters; assert the
  review-request source finds the trigger keyword through the adapter.
- **Work sources:** `Gitlab{Mr,Pipeline,ReviewRequest}Source` tests mirror the GitHub work-source
  suites (candidate detection, dedupe key, blocker/handoff outcomes).
- **End-to-end (Memory):** a `forge_type: "gitlab"` project flows through the dispatch wrapper to the
  GitLab sources and produces a dispatch + handoff, using `Forge.Memory` / seeded client responses.
- Gates: `mix format --check-formatted`, `mix specs.check`, `mix test` green; frontend untouched
  (API field names stay `github_*` per the Phase 1 Presenter mapping).

## Task sequence

1. Add `list_change_request_comments` to `Forge` + `Forge.Github` (+ `Forge.Memory`); repoint
   `GithubReviewRequestSource`'s comment fetch (parity-neutral; keeps GitHub green and retires the
   Phase 1 follow-up).
2. Forge-neutral credentials + handoffs: forge-aware `ProjectCreds.creds/2` (`GITLAB_TOKEN` for
   `gitlab`), `gitlab_client_opts/2`, and repoint the CI-fix / review handoffs through `Forge.adapter/1`.
3. `MergeRequest` / `Pipeline` / `Job` / `Note` structs.
4. `Gitlab.Client` (REST v4, `instance_url`, `request_fun`/`token`) — repo, MRs, pipelines+jobs+trace,
   notes, MR review.
5. `Forge.Gitlab` — implement every `Forge` callback, normalize.
6. `GitlabMrSource`.
7. `GitlabPipelineSource`.
8. `GitlabReviewRequestSource`.
9. `forge_type` dispatch wrapper in the orchestrator.
10. End-to-end test for a `gitlab` project; full-suite + format + specs gates.

The detailed task-by-task implementation plan lives in
`docs/superpowers/plans/2026-06-13-gitlab-adapter.md`.

## Out of scope (this phase)

- **GitLab webhooks** (pipeline/note events, controller, signature verification) — documented
  fast-follow.
- **Per-project credentials** (Phase 2) and the **repo/project picker** (Phase 3) — later in the
  agreed sequence.
- MR-level **approval** semantics (parity uses an MR note for review).
- Forge-agnostic **API field rename** (`github_* → forge_*`) — optional Milestone 5 in the parent plan.
- Trackers beyond Linear; forges beyond GitHub + GitLab.

## Risks

- **REST divergence** (pipelines vs Actions, namespace vs owner, MR `iid` vs PR `number`, notes vs
  comments) — absorbed by the normalized `Forge` shapes; work sources stay forge-specific where the
  richer fields matter. Mitigation: recorded fixtures per endpoint; `iid` handled explicitly on the
  rich structs.
- **Pipeline status vocabulary** — GitLab pipeline/job statuses must map cleanly onto the
  success/failure conclusion the CI-fix path expects. Mitigation: an explicit status-mapping function
  with table-driven tests.
- **CI-fix push policy** — GitHub's fork/protected-branch guard (`RepoPolicy`) has a GitLab analogue
  (fork MRs, protected branches). Mitigation: implement a GitLab push-policy check mirroring the
  GitHub guard before dispatching a pipeline fix.
