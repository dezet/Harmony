# Per-Project Credentials (Phase 2) — Design

**Status:** Draft for review

**Parent:** [Multi-Forge Platform](2026-06-13-multi-forge-platform-design.md) — Phase 2.

**Purpose:** Replace global-env-only credentials with **per-project secrets encrypted at rest**.
Each project carries its own forge token and tracker key, encrypted with `Cloak`, resolved at call
time, falling back to the existing global env vars when a project has none. The secret API is
**write-only** (never echoes a value, only a `set | unset` indicator). This is the foundation the
Phase 3 picker builds on — it validates repo/tracker access with the *project's* credentials.

## Context — where we are

- `Forge.ProjectCreds` (`forge/project_creds.ex`) already resolves credentials **per call**, but the
  only source is global env (`GITHUB_TOKEN`/`GH_TOKEN`, `GITLAB_TOKEN`, Linear `api_key`).
- `Storage.Project` has `forge_type` + `forge_*` columns but **no secret fields**.
- Phase 1 (forge abstraction + agnostic storage) and Phase 4 (GitLab) are merged. This phase adds the
  credential layer the picker (Phase 3) depends on.

## Decisions of record (from brainstorming)

1. **Cloak (encrypted-at-rest)** over the `$VAR`-reference or hand-rolled `:crypto` alternatives.
   Rationale: best UI flow ("paste a token, it disappears"), audited crypto, built-in multi-key
   rotation. It dominates `:crypto` at identical UX; `$VAR` is rejected because it breaks the
   "paste token in UI" flow the Phase 3 picker assumes.
2. **Both secrets now** — `forge_secret` *and* `tracker_secret`. Same Cloak mechanism applied twice;
   splitting only defers identical work into Phase 3 and leaves an inconsistency there (one secret
   encrypted, one in env).
3. **Hard fail-fast on the key** — `CLOAK_KEY` is required in **every** environment; a missing key
   crashes boot. No silent dev/test default, no lazy no-encryption mode. Implication: CI and the
   local test setup must export `CLOAK_KEY`.
4. **Resolve loads the project by slug** when only a `WorkRun` is in hand — the secret stays
   single-source-of-truth on `projects` and is never copied into `work_runs`.
5. **Clear via an explicit boolean** (`clear_forge_secret` / `clear_tracker_secret`), not a sentinel
   string and not omission. Omission leaves a secret unchanged.

## Architecture

### 1. Vault

`SymphonyElixir.Vault` (`Cloak.Vault`), cipher **AES-256-GCM**. The key is read from `CLOAK_KEY`
(Base64-encoded) via `System.fetch_env!/1` so a missing key raises at boot in **all** environments.
The Vault is configured as a **list of keys** (one tagged active) so a future key rotation is config
only — encrypt with the new key, decrypt against any. The key is an operational secret kept outside
the repo (env / secret manager), documented as an ops concern; losing it makes stored secrets
unrecoverable (by design — env fallback still works).

### 2. Storage + migration

`Storage.Project` gains two `Cloak.Ecto.Binary` fields: `forge_secret`, `tracker_secret`. A migration
adds two **nullable** `:binary` columns. **No backfill** — existing rows are `nil` and resolve via env
fallback, so the change is behaviorally inert until an operator sets a secret. Cloak encrypts on write
and decrypts on struct load transparently.

The changeset casts the secret fields but the **presenter/serializer never emits their values** — see
§4.

### 3. Credential resolution (per-call, per-secret fallback)

`ProjectCreds.forge_token/1` → `project.forge_secret || env(forge_type)`; the tracker key resolver →
`project.tracker_secret || env`. Fallback is **independent per secret**: a project may carry its own
forge token while its tracker key still comes from env.

When `ProjectCreds` is called with a `WorkRun` (which does not carry the secret), it **loads the
project by `slug`** to obtain the decrypted secret, then applies the same fallback. The secret is
never duplicated into `work_runs`.

### 4. Write-only secret API + form

- **Write:** create/update accepts `forge_secret` / `tracker_secret`. An **empty or absent** value
  leaves the stored secret **unchanged** (never overwrite with nil). Clearing a secret back to env
  fallback is an explicit `clear_forge_secret: true` / `clear_tracker_secret: true` flag.
- **Read:** the API/presenter **never returns a secret value** — only `forge_secret: "set" | "unset"`
  derived from `is_nil/1`.
- **Form:** a password-type field per secret, a `set | unset` badge, and a "Clear" button that sends
  the clear flag.

### 5. YAML sync interaction

`project_config/sync.ex` upserts projects from `projects/*.yaml`. Secrets are **UI/API-only and never
present in YAML**. Sync must **exclude the secret fields** from its attribute mapping so a re-sync (e.g.
on redeploy) does not null out a token entered through the UI. Without this, every redeploy wipes
credentials — this is a required part of the change, not an afterthought.

## Data flow

```
Configuration form → POST forge_secret/tracker_secret (or clear_* flag)
  → changeset casts → Cloak encrypts → projects.{forge,tracker}_secret
GET project → presenter → { forge_secret: "set"|"unset", tracker_secret: "set"|"unset" }   (no values)

Orchestrator poll → WorkSource → ProjectCreds (loads project by slug for the secret)
  → decrypt(project.forge_secret) || env(forge_type) → Forge.adapter(project).<op>(creds, …)
YAML sync → upsert projects EXCLUDING secret fields → existing UI-set secrets preserved
```

## Security

- Secrets encrypted at rest (AES-256-GCM via Cloak); the key lives outside the DB.
- API is write-only — a value is never echoed; the form shows only `set | unset`.
- `CLOAK_KEY` required in every environment (fail-fast); no silent unencrypted mode.
- Resolution is per-call from the project secret, global env only as fallback.
- Key rotation is config-only (Vault multi-key); documented as an ops concern.

## Testing

- Vault encrypt/decrypt round-trip.
- The API/presenter **never** returns a secret value — assert only `set | unset` is exposed.
- Resolution: project-with-secret uses it; project-without falls back to env; per-secret independently;
  resolution from a `WorkRun` loads the project by slug.
- YAML sync does **not** clear an existing UI-set secret.
- `CLOAK_KEY` added to the test environment (CI + local podman test setup).

## Out of scope

- Per-user OAuth / a user model (per-project secrets are the chosen model).
- Automated key-rotation tooling (the Vault supports multi-key; the rotation *procedure* is documented,
  not automated, in this phase).
- The Phase 3 picker (`list_repositories` / `list_projects`) — it consumes these credentials but is a
  separate phase.

## Risks

- **Key management** — at-rest security hinges on `CLOAK_KEY`. Mitigation: fail-fast in every env (no
  accidental unencrypted deploy), explicit ops doc, multi-key Vault for rotation.
- **YAML sync clobber** — a re-sync could null UI-set secrets. Mitigation: secret fields excluded from
  sync mapping, covered by a test.
- **CI friction from fail-fast** — every environment now needs `CLOAK_KEY`. Mitigation: add it to the
  test setup (CI + local podman) as part of this phase.
