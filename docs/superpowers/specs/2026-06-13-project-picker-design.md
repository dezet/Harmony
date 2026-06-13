# Project Picker (Phase 3) — Design

**Status:** Draft for review

**Parent:** [Multi-Forge Platform](2026-06-13-multi-forge-platform-design.md) — Phase 3. Builds on
[Per-Project Credentials](2026-06-13-per-project-credentials-design.md) (Phase 2, merged).

**Purpose:** Replace the free-text repo and tracker-project slugs in the Configuration form with
**searchable pickers** validated against the live forge/tracker using the credentials entered in the
form. Selecting a repository auto-fills owner/repo/default-branch; selecting a Linear project
auto-fills its slug and team. This also closes the Phase 2 loop by giving `tracker_secret` its first
consumer (`Tracker.list_projects`).

## Context — where we are

- `Forge.list_repositories(creds, opts)` and `get_repository(creds, owner, repo)` already exist and
  are implemented for GitHub and GitLab. Both return the normalized repo shape
  `%{owner, name, default_branch, url}`.
- `Tracker` is a behaviour with `fetch_*` callbacks but **no `list_projects`**; Linear + Memory
  adapters back it.
- The Configuration form (`elixir/assets/src/features/project/components/ProjectConfigForm.tsx`) uses
  free-text inputs for `github_owner`/`github_repo`/`github_base_branch` and
  `linear_project_slug`/`linear_team_key`. It does **not** expose `forge_type` or `forge_base_url`,
  though the controller already permits and stores them.
- Per-project secrets ship and the controller is write-only for them (Phase 2).

## Decisions of record (from brainstorming)

1. **Stateless, token-in-body endpoints.** The picker authenticates with the token currently in the
   form (works for both create and edit), posted to a read endpoint — not a saved secret. Token in
   the request **body** (never query string / logs). Falls back to the global env token when the
   form token is blank; blank token **and** no env → `422 missing_credentials`.
2. **Full list, client-side filter** (not server-side search). The endpoint returns the repos/projects
   (paginated up to a cap of **200**, with a truncation flag when more exist); the combobox filters in
   memory. Server-side typeahead is deferred (YAGNI) until a real large-account need appears.
3. **Picker only — no manual free-text fallback.** Selected values come from the picker; the fields
   are not free-text. Implication: configuring repo/tracker requires a working token and a reachable
   forge/tracker. API/auth failures surface as a toast with retry; they do not silently degrade.
4. **`forge_type` + `forge_base_url` join this phase.** The picker needs the forge type (and self-host
   URL) to know what to query, so the form gains a `forge_type` select (github | gitlab) and an
   optional `forge_base_url` input. Storage/controller already support both.

## Architecture

### 1. `Tracker.list_projects/1`

New behaviour callback:

```
@callback list_projects(creds) :: {:ok, [project]} | {:error, term}
```

`project` is normalized to `%{id, name, slug, team_key}` so selecting one fills both
`linear_project_slug` and `linear_team_key`. The Linear adapter issues a GraphQL query walking
`teams → projects`; `creds` carries the token (form token, env fallback). `Tracker.Memory` returns a
canned list for tests. (To verify during implementation: the exact field that maps to
`linear_project_slug` — Linear exposes `slugId` and `name`; pinned against recorded GraphQL fixtures.)

### 2. Read endpoints (stateless)

- `POST /api/v1/forge/repositories` — body `{forge_type, base_url, token}` →
  `{repositories: [%{owner, name, default_branch, url}], truncated: bool}`.
- `POST /api/v1/tracker/projects` — body `{token, base_url}` →
  `{projects: [%{id, name, slug, team_key}], truncated: bool}`.

POST (not GET) keeps the token out of the query string and access logs. A thin
`Forge.adapter_for(forge_type)` dispatches on the bare type (today `Forge.adapter/1` dispatches on a
project struct); the controller builds a `creds` map from the body and calls
`list_repositories/2` (capped at 200, paginating as needed).

### 3. Controllers

`ForgePickerController` and `TrackerPickerController` (or one `PickerController`) build `creds` from
the body, call the adapter, and map outcomes:

- success → `200` with the normalized list + `truncated`.
- blank token and no env → `422 missing_credentials`.
- forge/tracker `401` → `422 forge_auth_failed` / `tracker_auth_failed`.
- forge/tracker unreachable or `5xx` → `502 forge_unreachable` / `tracker_unreachable`.

### 4. Configuration form (React SPA)

- Add a **`forge_type`** select (github | gitlab) and an optional **`forge_base_url`** text input.
- Replace the `github_owner`/`github_repo`/`github_base_branch` triplet with a **repository
  Combobox** (shadcn). Opening it POSTs to `/api/v1/forge/repositories` with the current
  `forge_type` + `forge_base_url` + form token; choosing a repo fills `forge_owner` (owner),
  `forge_repo` (name), and `forge_base_branch` (default_branch).
- Replace `linear_project_slug` + `linear_team_key` with a **tracker-project Combobox**; choosing a
  project fills both from `slug` + `team_key`.
- In edit mode the current owner/repo (and slug) render as the combobox's selected label without an
  API call; the list loads only when the picker is opened.
- No free-text fallback (Decision 3): a failed list shows an inline error + retry, not editable inputs.

### 5. Data + hooks

React Query lazy triggers (`useForgeRepositories`, `useTrackerProjects`) fire on picker-open, not on
mount — a single request per open, results held in memory and filtered client-side. The contract
types (`contract.ts`) gain `ForgeRepository` and `TrackerProject` shapes kept in sync with the
presenter/controllers.

## Data flow

```
Form holds forge_type + forge_base_url + token (+ owner/repo/slug for display)
  open repo picker → POST /api/v1/forge/repositories {forge_type, base_url, token}
    → Forge.adapter_for(forge_type).list_repositories(creds) (cap 200)
    → combobox list → select → fill forge_owner/forge_repo/forge_base_branch
  open tracker picker → POST /api/v1/tracker/projects {token, base_url}
    → Tracker.list_projects(creds) → select → fill linear_project_slug/linear_team_key
Save → existing ProjectController create/update (+ Phase 2 secret write)
```

## Error handling

Token resolution and upstream failures are mapped to explicit codes (§3) and surfaced as toasts with
a retry affordance. The picker never falls back to free-text entry; the form is unusable for
repo/tracker selection only while credentials are missing or the upstream is down — a deliberate
consequence of Decision 3.

## Testing

- **Backend:** picker controllers exercised through `Forge.Memory` / `Tracker.Memory`;
  `Tracker.list_projects` (Linear) against recorded GraphQL fixtures; `Forge.adapter_for/1` dispatch;
  token→env fallback; the error-code mapping (missing creds, auth failed, unreachable).
- **Frontend:** picker component with mocked endpoints — open → list → select auto-fills the right
  fields; truncation note renders; auth/error states show the retry toast; `forge_type`/`base_url`
  drive which forge is queried; contract types type-check against fixtures.

## Out of scope

- Server-side typeahead / search (Decision 2 — deferred until a large-account need).
- A manual free-text fallback for repo/tracker fields (Decision 3).
- Per-project tracker resolution in the **poll** path (still global; the picker is the only
  per-project tracker consumer this phase).
- Forges/trackers beyond GitHub + GitLab + Linear.

## Risks

- **Configuring requires live credentials (Decision 3):** no offline/manual path. Mitigation:
  explicit, recoverable error states (retry toast); the token is entered in the same form, so the
  common path is self-contained.
- **Linear project→slug mapping:** the exact GraphQL field for `linear_project_slug` is unconfirmed.
  Mitigation: pin it against recorded fixtures during implementation before wiring the form.
- **Large accounts hit the 200 cap:** silent truncation reads as "complete." Mitigation: the endpoint
  returns a `truncated` flag and the combobox shows a "refine via the forge UI" note.
