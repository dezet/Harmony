# Multi-Forge Platform — Design

**Status:** Draft for review

**Purpose:** Evolve Harmony from a GitHub-only runner into a **multi-forge platform**: a pluggable
`Forge` abstraction (GitHub + GitLab, both self-hostable), forge-agnostic storage and config,
per-project credentials, and a project **picker** that lets operators choose a repo and a tracker
project from a list instead of typing slugs. This is one architecture delivered across four
dependency-ordered phases.

## Context — where we are

Harmony today polls Linear, runs Codex agents, opens GitHub PRs, watches CI, and hands off at
`Human Review`. The forge integration is **GitHub-only and tightly coupled**:

- ~83 `github_*` references across 19 files; `api.github.com` hardcoded in
  `github/client.ex` (so even GitHub Enterprise self-host is impossible today).
- No forge abstraction. Work sources (`work_sources/github_pr_source.ex`,
  `github_failed_ci_source.ex`, `github_review_request_source.ex`) call the GitHub client directly.
- Project config (`project_config/schema.ex`) and storage (`storage/project.ex`,
  `storage/work_run.ex`, `storage/pull_request_link.ex`) hardcode `github_*` fields.
- Credentials are **global env vars** (`GITHUB_TOKEN`/`GH_TOKEN`; tracker `api_key`).

The **tracker side already has the right pattern**: `SymphonyElixir.Tracker` is a behaviour with
Linear + Memory adapters, dispatched by `tracker.kind`, with a configurable endpoint
(`tracker.ex:40`, `linear/adapter.ex`, `tracker/memory.ex`). This design mirrors that pattern for
forges.

## Decisions of record (from brainstorming)

1. **Per-project credentials** (not global env): each project carries its own forge token + tracker
   key, encrypted at rest. Global env remains a fallback default.
2. **GitLab included now** (not deferred): a GitLab adapter + GitLab work sources ship as Phase 4 on
   the abstraction built in Phase 1.
3. **Full forge-agnostic storage now** (not incremental): `forge_type` + generic typed columns,
   migrating the ~83 `github_*` references.

## Architecture

### 1. `Forge` behaviour

New `SymphonyElixir.Forge` behaviour, mirroring `Tracker`:

```
@callback list_repositories(creds, opts)            :: {:ok, [repo]} | {:error, term}
@callback get_repository(creds, owner, repo)        :: {:ok, repo}   | {:error, term}
@callback list_change_requests(creds, repo_ref, opts) :: {:ok, [pr_or_mr]} | {:error, term}
@callback list_pipeline_runs(creds, repo_ref, head_sha) :: {:ok, [run]} | {:error, term}
@callback get_pipeline_logs(creds, repo_ref, run_id)   :: {:ok, binary} | {:error, term}
@callback create_comment(creds, repo_ref, change_id, body) :: {:ok, _} | {:error, term}
@callback create_review(creds, repo_ref, change_id, body)  :: {:ok, _} | {:error, term}
```

`repo` is a normalized shape (`{owner, name, default_branch, url}`); `pr_or_mr` and `run` normalize
GitHub PRs/Actions and GitLab MRs/pipelines to a common shape so work sources stay forge-neutral.
`Forge.adapter(project)` dispatches on `project.forge_type` (default `github`), exactly like
`Tracker.adapter/0`. A `Forge.Memory` adapter backs tests, mirroring `Tracker.Memory`.

Adapters: `Forge.Github` (REST, extracted from `github/client.ex`, base URL configurable) and
`Forge.Gitlab` (REST, `instance_url` configurable; namespace/group path instead of owner; MRs and
pipelines map onto the common shapes).

### 2. Forge-agnostic storage + config

**Shape: typed generic columns (not JSONB)** — preserves queryability and matches today's typed
`github_*` columns.

- `projects`: `forge_type` (`github` | `gitlab`), `forge_owner` (owner *or* GitLab namespace/group),
  `forge_repo`, `forge_base_branch`, `forge_base_url` (nullable; enterprise/self-host endpoint).
- `work_runs` + `pull_request_links`: rename `github_*` → `forge_*` (`forge_pr_number`,
  `forge_head_sha`, `forge_head_ref`, `forge_base_ref`).
- `project_config/schema.ex`: `forge: {type, owner, repo, base_branch, base_url?}` replacing
  `github: {...}`; `project_config/sync.ex` maps the new shape into storage.

**Migration is staged for safety:** add new columns → backfill from `github_*` (all existing rows are
`forge_type: "github"`) → repoint the ~83 references → drop the old columns. Each step is a separate,
reversible migration with tests.

### 3. Per-project credentials

A project stores its forge token and tracker key **encrypted at rest** (a `forge_secret` and
`tracker_secret`, encrypted with an app key — `Cloak`-style or `:crypto` with a key from env/secret).
Forge and tracker clients resolve credentials **at call time** from the project's secret, falling
back to the existing global env vars when a project has none (so current single-token deployments
keep working). The Configuration form accepts a token once and submits it; the API is **write-only**
for secrets — it never returns the value, only a `set | unset` indicator. Key management (where the
encryption key lives, rotation) is documented as an operational concern.

Lighter fallback if encrypted-at-rest proves too heavy: a per-project `$VAR`-reference model (store
the name of an env var/secret, not the value) — but it fits the "paste a token in the UI" flow worse.

### 4. Project picker

- `Forge.list_repositories/2` — GitHub `GET /user/repos` or `/orgs/{org}/repos`; GitLab
  `GET /projects?membership=true`. `Forge.get_repository/3` for the default branch.
- `Tracker.list_projects/1` — new Linear GraphQL query (teams → projects with slugs).
- Both use the **project's** credentials (hence the dependency on Phase 3).
- UI: in the Configuration tab, repo and tracker-project become **pickers** (searchable lists) instead
  of free-text slugs, validating access with the project's token. The rest of the form (base branch,
  review trigger, etc.) is unchanged.

### 5. GitLab adapter + work sources

`Forge.Gitlab` (REST, configurable `instance_url`): list projects/MRs, list pipelines + jobs (the CI
equivalent), post notes/MR comments, post reviews. `GitlabMrSource` and `GitlabPipelineSource` mirror
the GitHub work sources, registered under the same `WorkSource` behaviour and selected by the
project's `forge_type`. Self-hosted GitLab is just a configured `instance_url` — the same adapter
serves gitlab.com and a company instance.

## Data flow

```
Configuration form → picker (Forge.list_repositories + Tracker.list_projects, per-project creds)
  → project saved with forge_type + forge_* + encrypted secrets
Orchestrator poll → WorkSource (github_* or gitlab_*) → Forge.adapter(project).<op>(project_creds, …)
  → normalized PR/MR + pipeline shapes → run dispatch → handoff (Forge.create_comment/create_review)
```

## Security

- Secrets encrypted at rest; API write-only (never echoes a token); form shows `set | unset`.
- Forge/tracker base URLs configurable → GitHub Enterprise and self-hosted GitLab; no hardcoded host.
- Credential resolution is per-call from the project secret, global env only as fallback.
- The encryption key is an operational secret (env/secret manager), documented, not in the repo.

## Testing

- `Forge` behaviour exercised through both real adapters + `Forge.Memory` (mirrors `Tracker.Memory`).
- Storage migration: backfill correctness + reversibility tests; the 83-reference repoint covered by
  the existing work-source/handoff/storage suites.
- Secrets: encrypt/decrypt round-trip; assert the API never returns a secret value.
- Picker: shared contract fixtures for `list_repositories`/`list_projects`; client list-op tests;
  frontend component + e2e for the picker flow.
- GitLab: adapter tests against recorded REST fixtures; the MR/pipeline work sources mirror the
  GitHub work-source tests.

## Phasing

Dependency order forces the sequence. **Phase 1 is detailed to tasks in the implementation plan;
Phases 2-4 are milestones** there (the foundation will sharpen their details).

1. **Foundation** — `Forge` behaviour + `Forge.Github` (configurable base URL) + `Forge.Memory`;
   forge-agnostic storage migration + config schema; repoint all work sources/handoffs through the
   behaviour. End state: behaviorally identical to today, routed through the abstraction, storage
   generalized, GitHub Enterprise self-host configurable. Highest risk (the migration).
2. **Per-project credentials** — encrypted secret storage; forge/tracker auth resolved per-project
   with global-env fallback; write-only secret API + Configuration form field.
3. **Picker** — `Forge.list_repositories`/`get_repository` + `Tracker.list_projects`; Configuration
   tab pickers replacing free-text slugs.
4. **GitLab** — `Forge.Gitlab` (`instance_url`) + `GitlabMrSource` + `GitlabPipelineSource`.

## Out of scope

- Per-user OAuth / a user model (per-project secrets are the chosen credential model).
- Forges beyond GitHub + GitLab (Bitbucket etc.).
- Trackers beyond Linear (the tracker abstraction already exists; new trackers are a separate effort).
- Migrating the dashboard channel's full-state broadcast.

## Risks

- **Storage migration (Phase 1):** ~83 references + a multi-step column migration. Mitigation:
  staged add→backfill→repoint→drop, each reversible and tested; all existing rows are `github`.
- **Encryption key model (Phase 2):** at-rest secret security hinges on key management. Mitigation:
  explicit operational doc; `$VAR`-reference fallback if encrypted-at-rest is deferred.
- **GitHub/GitLab REST divergence (Phase 4):** pipelines vs Actions, namespace vs owner, MR vs PR.
  Mitigation: the normalized shapes in the `Forge` behaviour absorb the differences; work sources
  stay forge-neutral.
