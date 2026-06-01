# Harmony Production Roadmap Design

## Purpose

This document defines the roadmap for evolving Harmony from the manual proof-of-life run into a
production-oriented single-project automation service. The first target is one configured Linear
project mapped to one GitHub repository. Broader platform features, additional agent backends, and a
configuration UI come later.

## Current Baseline

The current Elixir runtime polls Linear issues, creates deterministic per-issue workspaces, runs
Codex app-server, exposes a dashboard/API, and keeps transient runtime state for running, retrying,
and blocked sessions. A manual proof-of-life run on the dedicated `harmony` system user confirmed:

- Harmony can poll Linear, create branches, open GitHub PRs, and observe CI.
- The workflow must stop at PR plus Linear `Human Review`.
- Harmony must not merge PRs, set Linear `Done`, or push directly to the base branch.
- The current host cannot use the expected bubblewrap sandbox because unprivileged user namespaces
  are restricted, so the proof-of-life uses `dangerFullAccess`.
- Systemd should remain manual until the runtime behavior is hardened and verified through
  controlled runs.

## Product Strategy

Use a production MVP first, then widen the platform.

1. Build a working single Linear project plus single GitHub repo runtime.
2. Add durable state and runtime policy before adding more agent backends.
3. Keep the first GitHub integration polling-based because that matches the current orchestrator.
4. Make `PR only, human merges` a runtime policy, not only a prompt convention.
5. Treat browser evidence for frontend work as a runtime-level requirement.

## MVP Scope

The MVP supports one configured project and three production workflows:

1. Linear issue implementation:
   - Read the Linear issue title, description, comments, and acceptance criteria.
   - Create a branch from the configured base branch.
   - Open a PR to the configured base branch.
   - Add a Linear issue link to the PR body.
   - Move the Linear issue to `Human Review` after the PR and required validation are ready.
   - Never merge the PR and never move the issue to `Done`.

2. Failed GitHub Actions repair:
   - Poll open GitHub PRs in the configured repo.
   - Select PRs whose GitHub Actions workflow run for the current head SHA failed.
   - Fetch workflow/check context and logs for the agent prompt.
   - Push fixes directly to the PR branch only when the branch is in the same repository, is not the
     base/protected branch, and the runtime has permission.
   - For forks, missing permission, or protected branches, create a repair branch or record a
     blocker/handoff.
   - If repair fails and a related Linear issue exists, comment and move it to `Human Review`.

3. `@hreview` PR review:
   - Poll PR comments only, not the PR body.
   - Use a configurable trigger string, defaulting to `@hreview`.
   - Run a configurable review prompt template.
   - Publish a formal GitHub pull request review with event `COMMENT`.
   - Do not publish automatic `REQUEST_CHANGES` in MVP.
   - In MVP, publish one aggregate review comment, not inline diff comments.

The MVP excludes Claude Code and Pi execution backends, inline diff comments, webhooks, automatic
merge, automatic Linear `Done`, multi-project UI, and multi-repo scheduling.

## Configuration Model

Use two layers of configuration:

- `WORKFLOW.md`: global runtime and agent contract.
- `projects/<slug>.yaml`: per-project configuration for the Linear/GitHub mapping.

The project YAML model should be able to seed or update Postgres records at startup. Later, the web
UI can edit the same model through the database without changing runtime semantics.

Project configuration includes:

- Linear project slug, team workflow state names, and `Human Review` state.
- GitHub repo owner/name, default base branch, and protected/base branch policy.
- GitHub polling settings.
- Failed CI trigger settings.
- Review trigger string and review template version.
- Prompt templates for implementation, CI fix, and review.
- Runtime policy knobs for PR-only behavior, blockers, and browser evidence.

## Durable Storage

Start with Postgres in the MVP. Durable state is required to avoid duplicate review/fix loops across
restarts and to support the future UI.

Initial data model:

- `projects`: active project configuration and resolved integration identifiers.
- `work_runs`: normalized unit of work, status, type, project, repo, PR, branch, issue link, and
  agent backend.
- `work_events`: append-only run history for polling, dispatch, agent updates, policy decisions, and
  external writes.
- `dedupe_keys`: unique processed keys for trigger suppression.
- `pull_request_links`: PR metadata and optional Linear issue association.
- `blockers`: durable blocker state with target PR and/or Linear issue.
- `artifacts`: browser evidence and other validation artifacts.

The existing in-memory state remains useful for active process coordination, but dedupe, blockers,
run history, and artifacts are persisted.

## Architecture

Add a `WorkSource` and `WorkRun` layer.

`WorkSource` implementations:

- `LinearIssueSource`: current Linear polling, adapted to emit `implementation` work runs.
- `GithubFailedCiSource`: GitHub open PR polling plus failed GitHub Actions detection.
- `GithubReviewRequestSource`: GitHub PR comment polling for the configured review trigger.

`WorkRun` normalizes all work into a common payload:

- project id and project config version,
- work type,
- repo and PR metadata,
- optional Linear issue association,
- target branch/base branch,
- prompt template and template version,
- dedupe key,
- required runtime policies and evidence requirements.

Supporting modules:

- `Github.Client`: GitHub REST API access for PRs, comments, workflow runs/logs, and reviews.
- `LinearLinkResolver`: maps PRs to Linear issues by Linear URL and issue identifiers such as
  `COD-123` in branch names, titles, PR bodies, and commits.
- `RepoPolicy`: decides whether a PR branch can be pushed to directly or requires a repair branch.
- `RuntimePolicy`: enforces PR-only, human-merge, blocker, and `Human Review` behavior.
- `Evidence`: validates browser tooling availability and records artifacts.
- `AgentBackend`: an interface introduced after MVP; Codex remains the only MVP backend.

GitHub and Linear polling produce candidates only. Deduplication, policy, dispatch, retries, and
status transitions are orchestrator decisions backed by Postgres.

## Workflow Details

### Linear Issue To PR

The runtime builds a `WorkRun` from an active Linear issue. The agent creates a branch, implements
the issue, opens a PR, validates the change, and hands off. Harmony verifies PR existence, base/head
branch policy, and required validation before moving the issue to `Human Review`.

If scope, acceptance criteria, required secrets, auth, permissions, or toolchains are missing,
Harmony records a blocker, comments on Linear, moves the issue to `Human Review`, and stops retrying
that blocker.

### Failed CI Repair

The runtime polls open PRs and examines GitHub Actions workflow runs for the current PR head SHA.
Only `conclusion=failure` GitHub Actions failures trigger MVP repair work. Third-party or unknown
status checks are observed but do not trigger automated repair.

Dedupe key:

```text
github-ci-fix:<repo_owner>/<repo_name>:<pr_number>:<head_sha>:<workflow_run_id>
```

Safe push policy:

- Same-repo PR branch: push directly only if not base/protected branch and token has permission.
- Fork PR: create a repair branch or record blocker/handoff.
- Missing permission: record blocker/handoff.

If repair cannot be completed, Harmony comments on the PR. If a Linear issue is linked, Harmony also
comments on Linear and moves it to `Human Review`.

### Review Trigger

The runtime polls PR comments and only reacts to the configured trigger string in comments.

Dedupe key:

```text
github-review:<repo_owner>/<repo_name>:<pr_number>:<trigger_comment_id>:<head_sha>:<review_template_version>
```

The review result is posted as a GitHub pull request review with event `COMMENT`. The review body
includes a processed marker containing the dedupe key or run id so humans and future tooling can
trace why the review was not repeated. A new trigger comment, new head SHA, or new template version
can intentionally trigger a new review.

Inline diff comments are a post-MVP milestone because correct line positioning, stale diff handling,
and comment volume control are separate quality problems.

## Runtime Policy And Hardening

Runtime policy must enforce the proof-of-life decisions:

- First-class `PR only, human merges` workflow.
- `Human Review` as an explicit runtime handoff state.
- Blocker flow as runtime behavior:
  - write PR and/or Linear comments,
  - persist the blocker,
  - move linked Linear issue to `Human Review` when appropriate,
  - suppress retry loops for the same blocker.
- Direct push and merge guard:
  - never push to the configured base branch,
  - reject known merge commands where the runtime can identify them,
  - verify PR head/base before handoff,
  - keep branch policy checks outside the prompt.
- Sandbox diagnostics:
  - detect bubblewrap availability,
  - detect AppArmor/user namespace restrictions where possible,
  - report when `dangerFullAccess` is active because workspace sandboxing is unavailable.
- Operational setup:
  - keep the dedicated `harmony` user,
  - keep manual proof-of-life runs before persistent systemd,
  - use `systemctl start` only after controlled runs,
  - use `systemctl enable` only after stable runtime behavior.

## Browser Evidence

Browser evidence is a runtime-level requirement for frontend changes.

MVP behavior:

- Detect frontend work by changed paths, project config, or agent handoff metadata.
- Verify that the `harmony` runtime can access the required browser MCP tooling.
- Require at least one artifact for frontend handoff: screenshot, trace, or validation report.
- Persist artifact metadata in Postgres and files under the configured Harmony artifact root.
- Block handoff to `Human Review` when evidence is required but missing.

Post-MVP behavior:

- Record Playwright video proof for configured scenarios.
- Attach artifact links to PR/Linear handoff comments.
- Add configured feature walkthrough scenarios per project.

## Agent Backends

Codex remains the only MVP execution backend because it is already integrated through app-server.

Post-MVP adds `AgentBackend` implementations:

- Codex app-server backend, extracted from the current runner.
- Claude Code backend after its non-interactive/runtime interface is validated.
- Pi backend after its RPC or JSON event stream mode is validated.

The interface should model:

- start session,
- run turn or task,
- stream events,
- handle tool/capability declarations,
- stop session,
- expose token/runtime metadata when available.

## Milestones

### Milestone 1: Postgres And Project Config Foundation

Deliverables:

- Ecto/Postgres configured for the Elixir app.
- Initial migrations for projects, work runs, events, dedupe keys, PR links, artifacts, and blockers.
- `projects/<slug>.yaml` parser and startup sync into Postgres.
- Tests for config validation and idempotent sync.

Done when Harmony can start with a Postgres-backed single-project config and preserve dedupe/run
state across restarts.

### Milestone 2: Runtime Policy Foundation

Deliverables:

- `WorkRun` model and orchestrator dispatch path.
- Existing Linear issue flow migrated onto `WorkRun`.
- Runtime-level PR-only, `Human Review`, blocker, and no-direct-push policy.
- Linear comment/state writes for blockers and handoff.

Done when the current proof-of-life behavior is enforced by runtime policy and not only by prompt
instructions.

### Milestone 3: GitHub Integration Foundation

Deliverables:

- GitHub client for open PRs, PR comments, workflow runs, workflow logs, and PR reviews.
- PR-to-Linear resolver by Linear URL and issue identifier.
- Polling sources for GitHub PR candidates.
- Observability for detected GitHub candidates without running agents.

Done when Harmony can poll the configured repo, detect candidate PRs, link known Linear issues, and
record all candidates durably.

### Milestone 4: Failed CI Fix Workflow

Deliverables:

- GitHub Actions failed-run detection for open PRs.
- CI log/check context in the agent prompt.
- Safe push/repair branch policy.
- PR/Linear comments and durable run history.
- Blocker handling for forks, missing permission, missing secrets, or unrepaired failures.

Done when Harmony can repair a failing same-repo PR branch or produce a deterministic blocker.

### Milestone 5: `@hreview` Workflow

Deliverables:

- PR comment trigger polling.
- Dedupe by trigger comment, head SHA, and template version.
- Configurable review prompt template.
- Formal GitHub PR review with event `COMMENT`.
- Processed marker in the review body.

Done when a single `@hreview` comment produces exactly one aggregate review for the current PR head
and does not loop after restart.

### Milestone 6: Browser Evidence MVP

Deliverables:

- Browser MCP capability check for the `harmony` runtime.
- Frontend-change evidence requirement.
- Artifact storage and metadata.
- Handoff blocker when required evidence is missing.

Done when frontend-changing runs cannot reach `Human Review` without recorded browser evidence.

### Milestone 7: Operations Hardening

Deliverables:

- Sandbox/bubblewrap diagnostics in logs and dashboard/API.
- Idempotent setup path for the `harmony` system user.
- Runtime port/config cleanup.
- Manual-run checklist before systemd start.
- Clear systemd start/status guidance, with enable reserved for stable runs.

Done when a new host can repeat the proof-of-life setup predictably and the runtime reports its
sandbox posture clearly.

### Milestone 8: Platform Expansion

Deliverables:

- `AgentBackend` interface and Codex extraction.
- Claude Code backend.
- Pi backend.
- Multi-project scheduling.
- Database-backed web configuration UI.
- Inline diff review comments.
- GitHub webhooks.
- Playwright video proof and project walkthrough scenarios.

Done when Harmony can operate more than one project and select from multiple agent backends without
changing workflow semantics.

## Validation Strategy

Each milestone should include focused ExUnit coverage and at least one controlled manual run when it
touches external systems. External integration tests should use disposable PRs/issues or fixtures
where possible.

Key validation targets:

- Dedupe survives restart.
- Blockers do not retry-loop.
- PR base/head branch guards reject unsafe writes.
- `@hreview` review does not repeat for the same comment/SHA/template.
- Failed CI repair does not trigger on non-GitHub-Actions status checks.
- Frontend handoff fails without required browser evidence.
- Runtime reports unavailable sandboxing accurately.

## References

- GitHub REST Pulls API: https://docs.github.com/en/rest/pulls/pulls
- GitHub REST Pull Request Reviews API: https://docs.github.com/en/rest/pulls/reviews
- GitHub REST Actions Workflow Runs API: https://docs.github.com/en/rest/actions/workflow-runs
- GitHub REST Checks API: https://docs.github.com/en/rest/checks/runs
- Playwright MCP: https://github.com/microsoft/playwright-mcp
- Playwright video recording: https://playwright.dev/docs/videos
- Chrome DevTools MCP: https://developer.chrome.com/blog/chrome-devtools-mcp-debug-your-browser-session
- Claude Code overview: https://code.claude.com/docs/en/overview
- Pi documentation: https://pi.dev/docs/latest
