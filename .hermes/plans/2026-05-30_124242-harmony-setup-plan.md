# Plan: Harmony on private Hermes server

Created: 2026-05-30 12:42 UTC

## Goal

Prepare a shared implementation plan for:

1. Cloning `https://github.com/dezet/Harmony` into the Hermes workspace for local development.
2. Running Harmony/Symphony on this server as a trusted, private orchestration service.
3. Exposing the Harmony dashboard/API only to the user, without public internet exposure.
4. Creating a clear path for later changes, especially adding more providers beyond the current Linear/Codex-centered reference implementation.

## Current context

- `dezet/Harmony` is a public fork of `openai/symphony`.
- Upstream `openai/symphony` describes Symphony as an engineering preview for trusted environments.
- The reference implementation lives under `elixir/`.
- The service:
  - polls Linear for candidate work,
  - creates one workspace per issue,
  - launches `codex app-server` inside each workspace,
  - uses repo-owned `WORKFLOW.md` YAML front matter plus prompt body as the runtime contract,
  - can expose a Phoenix LiveView dashboard and JSON API when started with `--port`.
- The upstream docs recommend `mise` for Elixir/Erlang versions and show the run path:
  - `mise trust`
  - `mise install`
  - `mise exec -- mix setup`
  - `mise exec -- mix build`
  - `mise exec -- ./bin/symphony ./WORKFLOW.md`
- External source references:
  - Harmony repo: https://github.com/dezet/Harmony
  - Upstream Symphony repo: https://github.com/openai/symphony
  - OpenAI article: https://openai.com/pl-PL/index/open-source-codex-orchestration-symphony/
  - Elixir README: https://raw.githubusercontent.com/dezet/Harmony/main/elixir/README.md
  - Spec: https://raw.githubusercontent.com/dezet/Harmony/main/SPEC.md

## Assumptions

- This plan is for a single-user private deployment first, not multi-tenant production.
- The service should not bind to a public interface.
- Tailscale is the selected private network path.
- As of 2026-05-30, Tailscale's official pricing page describes the Personal plan as free for individuals, and the docs state it permits 6 free users in one tailnet. This should be rechecked before any business/commercial use.
- The server can run long-lived services via `systemd`.
- Hermes and Harmony can coexist in `/var/lib/hermes/workspaces/default/`.
- We will not add internet-facing reverse proxy configuration unless explicitly requested later.
- The user already uses Linear, so Linear remains the first production tracker.
- First Linear project:
  - URL: `https://linear.app/code-monkeys-dd/project/portal-6d90492ea04f/overview`
  - project slug: `portal-6d90492ea04f`
- GitHub Issues / GitHub Projects are roadmap providers, not phase-one blockers.
- The first Harmony version should handle the full workflow cycle, including branches/PRs/status transitions if the upstream Elixir implementation and workflow support it.
- First target code repository:
  - `https://github.com/dezet/portal`
- First full-cycle test should use the real `dezet/portal` repo with a deliberately low-risk Linear issue.
- Linear workflow states will be adjusted to match upstream before first full-cycle test:
  - `Rework`
  - `Human Review`
  - `Merging`
- The server already has `gh` CLI authenticated with the user's GitHub account, expected to have access to private repositories.
- For tests, Harmony/Codex may use the existing Hermes/Codex/GitHub credentials.
- Target long-term state: dedicated Harmony identity and credentials, not the user's personal `gh` session.
- Linear workflow statuses should be created/updated via Linear API if possible.
- Required for Linear API configuration:
  - `LINEAR_API_KEY` with permission to read teams/projects/issues and update team workflow states.
- Long-term GitHub auth preference:
  - fine-grained PAT for Harmony, scoped to required repositories and permissions.

## Recommended architecture

Use a private local service plus Tailscale access:

- Clone Harmony to:
  - `/var/lib/hermes/workspaces/default/Harmony`
- Store Harmony runtime workspaces outside the repo:
  - `/var/lib/hermes/workspaces/default/harmony-workspaces`
- Store logs outside the repo:
  - `/var/lib/hermes/workspaces/default/harmony-logs`
- Run the Phoenix dashboard on loopback or Tailscale-only bind:
  - safest default: bind to `127.0.0.1`, then access through Tailscale SSH/local forwarding
  - more convenient: bind to the server's Tailscale IP only, firewall deny all non-Tailscale access
- Run Harmony with a dedicated `WORKFLOW.md` for the first target repo/project.
- For the first deployment, run one Harmony instance for one Linear project:
  - `tracker.project_slug: portal-6d90492ea04f`
  - target repo cloned in workspaces from `https://github.com/dezet/portal`
- Manage secrets via environment files with restricted permissions:
  - `LINEAR_API_KEY`
  - Codex/OpenAI authentication already available to the `hermes` user or explicitly configured for the service user
  - future provider tokens kept out of git

User/service account recommendation:

- Start with a dedicated `harmony` system user for the long-running service if practical.
- Add controlled access for Hermes through filesystem group permissions and documented commands instead of running everything as the same user.
- If Codex authentication or Hermes integration makes this too slow for the first run, use `hermes` temporarily, then migrate to `harmony` after the manual proof-of-life.
- For GitHub, use existing `gh` CLI credentials during the first test, then migrate to a dedicated Harmony bot/user/token once the full cycle is proven.
- For Linear, use `LINEAR_API_KEY` both for Harmony runtime and for one-time workflow-state configuration.

Reasoning:

- A dedicated `harmony` user gives a clearer security boundary for a long-running daemon that launches agents.
- Hermes can still inspect logs, edit the repo, update workflows, and manage the service via explicit permissions.
- Using `hermes` is faster but shares credentials and broad filesystem access with the orchestration daemon.
- Using the user's existing `gh` login is acceptable for the first controlled test, but it makes audit trails and blast radius worse than a dedicated bot identity.

Multi-project Linear support:

- Current upstream spec and documented workflow use a single `tracker.project_slug` string, required when `tracker.kind=linear`.
- The Linear adapter contract says candidate issue fetching is for a configured project.
- Based on that contract, assume the current Elixir implementation handles one Linear project per running Symphony/Harmony instance.
- To support multiple Linear projects, choose one of these later:
  - run multiple service instances, each with its own `WORKFLOW.md`, workspace root, logs root, and port;
  - extend config from `project_slug` to `project_slugs` and update the Linear adapter, orchestration keys, dashboard grouping, and tests.
- Recommended first approach for multiple projects: separate instances. It is simpler, isolates failures, and avoids modifying the core scheduler before the first production run.

## Access options

### Option A: Tailscale SSH tunnel, most conservative

Harmony binds only to `127.0.0.1:4000` on the server.

The user connects through Tailscale SSH or regular SSH over Tailscale:

```bash
ssh -L 4000:127.0.0.1:4000 hermes@<server-tailscale-name>
```

Then open:

```text
http://127.0.0.1:4000
```

Pros:

- Nothing listens on the public network.
- Minimal firewall risk.
- Easy to turn off by closing the SSH tunnel.

Cons:

- Requires opening a tunnel before using the UI.

Decision: use this option first.

### Option B: Bind dashboard to Tailscale IP

Harmony listens on the server's Tailscale IP and port, for example:

```text
http://100.x.y.z:4000
```

Pros:

- Convenient direct browser access from the user's Tailscale devices.

Cons:

- We must verify the Phoenix/Bandit bind host support in Harmony config or startup code.
- We should enforce firewall rules so the port is reachable only from `tailscale0`.

### Option C: VPN other than Tailscale

WireGuard or another VPN would work, but it has more operational overhead. Use it only if Tailscale is not acceptable.

## Proposed implementation phases

### Phase 1: Repository setup

1. Clone `https://github.com/dezet/Harmony` into `/var/lib/hermes/workspaces/default/Harmony`.
2. Add upstream remote for comparison:
   - `origin`: `dezet/Harmony`
   - `upstream`: `openai/symphony`
3. Inspect the repo structure:
   - `README.md`
   - `SPEC.md`
   - `elixir/README.md`
   - `elixir/WORKFLOW.md`
   - `elixir/mix.exs`
   - `elixir/config/*`
   - `elixir/lib/*`
   - `elixir/test/*`
4. Record current commit SHAs for both fork and upstream.
5. Create a working branch for local deployment changes, for example:
   - `server-private-deployment`

### Phase 2: Runtime prerequisites

1. Check whether these commands are installed for the runtime user:
   - `git`
   - `mise`
   - `elixir`
   - `erl`
   - `mix`
   - `codex`
   - `tailscale`
2. Install and enroll Tailscale on the server:
   - install Tailscale from official packages for the server OS,
   - run `tailscale up`,
   - authenticate with the user's Tailscale account,
   - verify the server appears in the tailnet,
   - keep Harmony dashboard bound to localhost and use SSH forwarding over Tailscale.
3. If `mise` is missing, install it for the server/user and let it manage Elixir/Erlang versions from the repo's tool config.
4. Verify Codex app-server support:
   - `codex app-server --help`
   - optionally generate/inspect the local app-server schema if needed.
5. Decide whether Harmony should run as:
   - the existing `hermes` user, or
   - a dedicated `harmony` service user.

Recommendation: prefer dedicated `harmony` for the service; allow Hermes access through group permissions and service-management commands. Use `hermes` only as a temporary bootstrap shortcut if Codex auth blocks progress.

### Phase 3: First local run

1. In `Harmony/elixir`, run the documented setup:
   - `mise trust`
   - `mise install`
   - `mise exec -- mix setup`
   - `mise exec -- mix build`
2. Create a first private `WORKFLOW.md`, likely outside upstream defaults:
   - `elixir/WORKFLOW.local.md`, ignored by git, or
   - `/var/lib/hermes/workspaces/default/harmony-config/WORKFLOW.md`
3. Configure full-cycle Linear runtime, initially with conservative concurrency:

```yaml
---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "portal-6d90492ea04f"
  active_states: ["Todo", "In Progress", "Rework"]
  terminal_states: ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"]
polling:
  interval_ms: 30000
workspace:
  root: /var/lib/hermes/workspaces/default/harmony-workspaces
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex app-server
  thread_sandbox: workspace-write
---

You are working on Linear issue {{ issue.identifier }}.

Title: {{ issue.title }}

Body:
{{ issue.description }}
```

4. Use the upstream workflow as the baseline if it already implements the full Linear lifecycle:
   - claim or move issues into active states,
   - create branches,
   - implement changes,
   - run validation,
   - push branches,
   - open or update PRs,
   - move issues to review/merging/done states as appropriate.
5. Configure `hooks.after_create` to clone the target repo:
   - preferred first form: `git clone git@github.com:dezet/portal.git .`
   - fallback if deploy key/auth is not ready: `git clone https://github.com/dezet/portal .`
   - use SSH once write/push/PR workflow is needed.
6. Align Linear statuses with upstream `WORKFLOW.md`:
   - current Linear setup is basic,
   - add upstream-style states first:
     - `Rework`
     - `Human Review`
     - `Merging`
   - final names should match the workflow prompt and `tracker.active_states`.
7. Configure Linear states through API if token permissions allow:
   - discover team connected to project `portal-6d90492ea04f`,
   - list current workflow states,
   - create missing states `Rework`, `Human Review`, and `Merging`,
   - confirm state types/order/colors if Linear requires them,
   - fall back to manual Linear UI only if API permissions or schema constraints block it.
8. Confirm GitHub CLI access from the runtime context:
   - `gh auth status`
   - `gh repo view dezet/portal`
   - ability to push a branch or at least verify repo permissions before the full-cycle run.
9. Start with very conservative concurrency:
   - `max_concurrent_agents: 1`
   - `max_turns: 20`
10. Run locally without systemd first:
   - `LINEAR_API_KEY=... mise exec -- ./bin/symphony /path/to/WORKFLOW.md --logs-root /var/lib/hermes/workspaces/default/harmony-logs --port 4000`
11. Confirm:
   - service boots,
   - workflow parses,
   - dashboard/API responds locally,
   - no public listener is exposed,
   - logs are written,
   - a test issue can complete the full intended cycle in a disposable branch/PR.

### Phase 4: Private access

Preferred first implementation: Option A, Tailscale SSH tunnel.

1. Install Tailscale on the server.
2. Authenticate the server into the user's tailnet.
3. Verify Tailscale status:
   - server is connected to tailnet,
   - user device is connected,
   - SSH over Tailscale works.
4. Keep Harmony dashboard bound to localhost.
5. Access through:
   - `ssh -L 4000:127.0.0.1:4000 hermes@<server-tailscale-name>`
6. Open `http://127.0.0.1:4000` locally.
7. Only after this works, evaluate whether direct Tailscale-IP binding is worth the extra firewall/config work.

### Phase 5: systemd service

After a successful manual run:

1. Create an environment file, for example:
   - `/var/lib/hermes/.config/harmony/harmony.env`
2. Store only secrets and runtime paths there:
   - `LINEAR_API_KEY=...`
   - optional `SYMPHONY_WORKSPACE_ROOT=...`
3. Create a `systemd` unit:
   - working directory: `/var/lib/hermes/workspaces/default/Harmony/elixir`
   - command: `mise exec -- ./bin/symphony /path/to/WORKFLOW.md --logs-root /path/to/logs --port 4000`
   - restart policy: `on-failure`
   - network dependency: after network/Tailscale if using Tailscale-bound access
4. Keep the service disabled until manual run is proven.
5. Enable and start only when the workflow is stable.
6. Initially, if running as `hermes`, document that this is a temporary bootstrap mode.
7. Migration to dedicated `harmony` user:
   - create system user and group,
   - copy or recreate only required Codex auth,
   - configure dedicated GitHub credential:
     - preferred: fine-grained PAT with access only to required repositories,
     - initial repo access: `dezet/portal`,
     - required permissions likely include repository contents read/write, pull requests read/write, metadata read, and checks/statuses read,
     - issues permission is optional if Linear remains the tracker,
     - alternative later: GitHub App for stronger auditability and rotation,
   - run `gh auth status` as `harmony`,
   - grant Hermes read/manage access to logs, workflow config, and systemd unit through group permissions or sudoers rules.

### Phase 6: Development path for provider expansion

The upstream spec currently names Linear as the tracker supported by this spec version. Adding providers should be done as explicit integration-layer work, not by mixing provider-specific conditionals through the orchestrator.

Likely direction:

1. Identify current Linear adapter modules under `elixir/lib`.
2. Extract or confirm a tracker behaviour/interface:
   - fetch candidate issues,
   - fetch current states,
   - fetch terminal issues for cleanup,
   - normalize payload into the spec's issue model.
3. Keep the orchestrator consuming normalized issues only.
4. Add provider-specific config under `tracker.kind`.
5. Add one provider at a time with tests.

Candidate provider roadmap:

- Linear:
  - phase-one production provider
  - use existing implementation first
  - inspect whether project/status names need local customization
- GitHub Issues:
  - `tracker.kind: github`
  - token from `GITHUB_TOKEN`
  - repo owner/name, labels, states, project/status mapping
- GitHub Projects:
  - more complex, but closer to Linear boards
  - requires GraphQL mapping and field/status configuration
- Jira:
  - useful but heavier due to custom workflows and auth variations
- Local markdown/YAML issues:
  - good for testing without external services
  - useful as a first new provider because it avoids API auth and makes tests deterministic

Recommended provider sequence:

1. Linear first, using the existing implementation.
2. Local file provider second if we want architecture tests without external APIs.
3. GitHub Issues third for practical non-Linear usage.
4. GitHub Projects later, because status/field mapping is more complex.

Multi-project roadmap:

1. Phase one: one Harmony process for `portal-6d90492ea04f`.
2. If a second Linear project is needed soon, create a second `WORKFLOW.md`, logs root, workspace root, and service unit.
3. If multiple projects become common, add first-class multi-project support:
   - config accepts `project_slugs: [...]`,
   - tracker queries paginate per project,
   - issue identity keys include project slug where needed,
   - dashboard groups runs by project,
   - cleanup and reconciliation remain project-aware,
   - tests cover cross-project duplicate issue identifiers and concurrent runs.

## Files likely to change later

Exact paths need confirmation after cloning, but likely areas are:

- `Harmony/elixir/README.md`
- `Harmony/elixir/WORKFLOW.md`
- `Harmony/elixir/mix.exs`
- `Harmony/elixir/lib/**`
- `Harmony/elixir/test/**`
- new local deployment docs, for example:
  - `Harmony/docs/private-server-deployment.md`
- local-only files that should not be committed:
  - `Harmony/elixir/WORKFLOW.local.md`
  - `.env` files
  - runtime logs
  - runtime workspaces

## Validation checklist

### Before running agents

- Repo cloned and upstream remote recorded.
- Dependencies install cleanly.
- `mix test` or `make all` passes.
- `codex app-server` is available for the runtime user.
- `LINEAR_API_KEY` is present only in a private env file or shell environment.
- Dashboard binds only to localhost or Tailscale IP.
- Firewall does not expose dashboard port publicly.

### First orchestration test

- Use a disposable Linear project or a clearly marked test issue.
- Set `max_concurrent_agents: 1`.
- Use a harmless workflow prompt first, for example read-only analysis/commenting.
- Confirm workspace creation under the configured workspace root.
- Confirm logs and dashboard state.
- Confirm terminal issue cleanup behavior.

### Provider development tests

- Unit tests for config parsing and defaults.
- Unit tests for provider payload normalization.
- Integration test with mocked provider responses.
- Optional live test behind explicit environment variables only.
- Regression test that orchestrator behavior does not depend on provider-specific payloads.

## Risks and tradeoffs

- Harmony/Symphony is explicitly preview/prototype software, so we should treat it as trusted-environment automation, not a hardened public service.
- A coding agent can execute code in per-issue workspaces; sandbox and filesystem boundaries matter.
- Running under the existing `hermes` user is easier but shares credentials and permissions.
- A dedicated `harmony` user is cleaner but requires separate Codex auth and more setup.
- Binding directly to the Tailscale IP is convenient but requires careful firewall and bind-host verification.
- Linear-specific assumptions may be spread through the code; provider expansion may require refactoring before adding real integrations.
- Dashboard/API authentication may be absent or minimal, so network isolation is the primary access control unless we add auth.

## Open questions for the user

Answered:

1. The user already uses Linear; GitHub Issues/Projects are roadmap items.
2. Tailscale is not installed on the server yet; the user has a Tailscale account.
3. The user wants Hermes to have access to Harmony as an agent. Recommendation: dedicated `harmony` service user plus explicit Hermes access.
4. First access mode: SSH tunnel over Tailscale.
5. First version should support the full workflow cycle.
6. First Linear project slug is `portal-6d90492ea04f`.
7. First target repository is `https://github.com/dezet/portal`.
8. Linear currently has a basic workflow and may need extra states to match upstream `WORKFLOW.md`.
9. First full-cycle test will use the real repo with a low-risk issue.
10. Linear will be configured with upstream-style states before first run.
11. Initial PR creation and repo access can use existing authenticated `gh` CLI credentials.
12. Long-term target is a dedicated Harmony identity/token/user.
13. Linear workflow states should be configured through Linear API when possible.
14. Long-term GitHub auth should use a fine-grained PAT scoped to required repos/permissions.

Still open:

1. What exact Linear team/workflow should receive the new statuses for project `portal-6d90492ea04f`? We can discover this from the project via API if `LINEAR_API_KEY` is available.
2. Where should secrets live on this server for the first run:
   - shell-only during manual test,
   - `/var/lib/hermes/.config/harmony/harmony.env`,
   - another path?
3. For the future fine-grained PAT, should it be tied to the user's account initially or a separate Harmony/bot account?

## Suggested next action

For the next execution turn, do this in order:

1. Ask/answer the open questions enough to choose first provider and access mode.
2. Clone `dezet/Harmony` into `/var/lib/hermes/workspaces/default/Harmony`.
3. Inspect the Elixir implementation and confirm actual module/file names.
4. Install and authenticate Tailscale on the server.
5. Verify server prerequisites.
6. Prepare a local-only workflow and a manual localhost run.
7. Configure Linear workflow states for `portal-6d90492ea04f` through Linear API using `LINEAR_API_KEY`.
8. Test full-cycle Linear flow on a low-risk real issue in `dezet/portal`.
9. Only then create persistent `systemd` service and private access path.
10. After proof-of-life, migrate from personal/Hermes credentials to dedicated Harmony credentials.

## Implementation Plan

This section turns the brainstorm into an execution plan. It should be followed in order, because each phase reduces uncertainty before the next one changes more server state.

## Execution Log

### 2026-05-30: Phases 1-4

Completed:

- Cloned `https://github.com/dezet/Harmony` to `/var/lib/hermes/workspaces/default/Harmony`.
- Added upstream remote `https://github.com/openai/symphony.git`.
- Current `origin` and `upstream` HEAD both resolve to `c5261d12101b02e0045ca84701eed0c4be367387`.
- Confirmed Elixir implementation layout:
  - CLI: `elixir/lib/symphony_elixir/cli.ex`
  - config/schema: `elixir/lib/symphony_elixir/config.ex`, `elixir/lib/symphony_elixir/config/schema.ex`
  - Linear client/adapter: `elixir/lib/symphony_elixir/linear/client.ex`, `elixir/lib/symphony_elixir/linear/adapter.ex`
  - dashboard server: `elixir/lib/symphony_elixir/http_server.ex`, `elixir/lib/symphony_elixir_web/endpoint.ex`
- Confirmed current implementation is one Linear project per Harmony instance:
  - config schema has `tracker.project_slug` as a single string,
  - Linear query filters by one `$projectSlug`.
- Confirmed dashboard can bind privately:
  - config has `server.host`, default `127.0.0.1`,
  - CLI has `--port`,
  - workflow config can set `server.host: "127.0.0.1"`.
- Confirmed CLI requires explicit guardrails acknowledgement flag:
  - `--i-understand-that-this-will-be-running-without-the-usual-guardrails`
- Verified tools:
  - `git`: installed
  - `gh`: installed and authenticated as `dezet`
  - `gh repo view dezet/portal`: succeeds with `ADMIN` permission
  - `codex app-server --help`: succeeds
  - `curl`, `jq`, `systemctl`: installed
- Installed `mise` locally for `hermes` at `/var/lib/hermes/.local/bin/mise`.
- Installed repo-required runtime through `mise`:
  - Erlang/OTP 28
  - Elixir 1.19.5 / Mix 1.19.5
- Queried Linear project via API:
  - project name: `Portal`
  - project id: `5a53a112-f657-491f-b17e-e6dc38bf892c`
  - project slugId returned by API: `6d90492ea04f`
  - team: `Code Monkeys DD`
  - team key: `COD`
  - team id: `0f614b0c-e7ff-4643-a1c2-295bf4d9c552`
- Created missing Linear workflow states through API:
  - `Human Review`, type `started`, position `2.3`
  - `Rework`, type `started`, position `2.4`
  - `Merging`, type `started`, position `2.5`
- Re-read Linear states and confirmed the new states exist.

- Tailscale was installed/enrolled by the user with admin privileges.
- Verified Tailscale from Hermes:
  - binary: `/usr/bin/tailscale`
  - service: `tailscaled.service` active
  - server name: `ns3131012`
  - server Tailscale IPv4: `100.125.155.110`
  - another tailnet node visible: `king` at `100.76.175.124`

Operational notes:

- The shell prints an nvm/npm warning on most commands:
  - `${HOME}/.npmrc` has `globalconfig` and/or `prefix`, incompatible with nvm.
  - This warning has not blocked the Harmony work so far.
- Temporary helper scripts were created under `.hermes/tmp/` for Linear API probing. They do not contain secret values.
- The provided Linear API key was used for API calls but was not written to the markdown plan.

Recommended immediate next step:

1. Decide whether the next implementation step is:
   - fast path: run current single-project Harmony for `Portal`, or
   - product path: add first-class multi-project Linear support before the first serious run.
2. Proceed to Phase 5: `mix setup`, build, and tests.
3. Later validate dashboard access through SSH tunnel over Tailscale once Harmony is running.

### 2026-05-30: Multi-project requirement added

New requirement:

- Harmony should support more than one Linear project.
- The UI should be adjusted accordingly:
  - project selector,
  - per-project board/status view,
  - project-aware issue/run grouping,
  - likely project filter in JSON API/dashboard state.

Why this matters now:

- The current code and spec use one `tracker.project_slug` string.
- Workspaces, dashboard labels, Linear polling, and orchestration identity currently assume one configured project.
- Adding this before systemd/workflow hardening avoids baking the first deployment around a shape we already know is insufficient.

Recommended approach:

- Still build and test the current repo first to establish a green baseline.
- Then implement native multi-project support as a focused feature branch before the first long-running production service.
- Keep single-project config backwards compatible so upstream-style examples and tests still work.

Proposed multi-project config shape:

```yaml
tracker:
  kind: linear
  project_slug: "portal-6d90492ea04f" # legacy single-project form, still supported
```

```yaml
tracker:
  kind: linear
  project_slugs:
    - "portal-6d90492ea04f"
    - "<another-project-slug>"
```

Potential richer future shape:

```yaml
tracker:
  kind: linear
  projects:
    - slug: "portal-6d90492ea04f"
      name: "Portal"
      repo: "git@github.com:dezet/portal.git"
      workspace_prefix: "portal"
```

Initial recommendation:

- Add `project_slugs` first, not the richer per-project repo map.
- Keep repo cloning/workflow behavior global for the first multi-project version.
- Add per-project repo mapping only when we need Harmony to orchestrate different repositories per Linear project from one process.

### Phase 0: Operating model and secrets

Goal: make the working model explicit before touching the server.

Decisions:

- Hermes can work only while the conversation/task is active. It does not continue autonomously after the chat turn ends.
- Long-running server processes can be created later through `systemd`, but implementation and supervision still happen through explicit turns.
- Secrets must not be committed to git or written into markdown plans.
- `LINEAR_API_KEY` has been provided in chat for execution, but should be stored only in a private env file or shell environment when used.
- Because the key appeared in chat history, rotate it after the first successful setup if strict secret hygiene is required.

Deliverables:

- This implementation plan.
- Agreement that next turn may execute commands and make server changes.

Validation:

- No secret values appear in repo files or plan files.

### Phase 1: Clone and inspect Harmony

Goal: bring the code into the workspace and confirm actual implementation details.

Steps:

1. Clone `https://github.com/dezet/Harmony` into `/var/lib/hermes/workspaces/default/Harmony`.
2. Add upstream remote `https://github.com/openai/symphony`.
3. Record `origin` and `upstream` commit SHAs.
4. Inspect:
   - `README.md`
   - `SPEC.md`
   - `elixir/README.md`
   - `elixir/WORKFLOW.md`
   - `elixir/mix.exs`
   - `elixir/config/*`
   - `elixir/lib/**`
   - `elixir/test/**`
5. Identify:
   - Linear adapter modules,
   - dashboard/API config,
   - hooks syntax,
   - PR/GitHub expectations,
   - whether command-line flags support host binding or only port.

Validation:

- Repo exists locally.
- Worktree status is clean after clone.
- We know exact files to modify or configure.

### Phase 2: Server prerequisites

Goal: verify installed tools before installing anything.

Steps:

1. Check:
   - `git`
   - `gh`
   - `codex`
   - `mise`
   - `elixir`
   - `erl`
   - `mix`
   - `tailscale`
   - `systemctl`
2. Check GitHub auth:
   - `gh auth status`
   - `gh repo view dezet/portal`
3. Check Codex app-server availability:
   - `codex app-server --help`
4. If `mise` or Elixir tooling is missing, install/configure with the repo's documented path.

Validation:

- `gh` can see `dezet/portal`.
- `codex app-server` exists for the selected runtime user.
- Elixir dependencies can be installed through `mise`/`mix`.

### Phase 3: Tailscale private access

Goal: add private network access without exposing Harmony publicly.

Steps:

1. Install Tailscale if missing.
2. Run `tailscale up` and authenticate with the user's account.
3. Verify the server appears in the tailnet.
4. Keep Harmony bound to `127.0.0.1`.
5. Access dashboard through SSH forwarding over Tailscale:
   - `ssh -L 4000:127.0.0.1:4000 hermes@<server-tailscale-name>`

Validation:

- Server is reachable over Tailscale.
- No Harmony port is exposed publicly.

Current status:

- Complete enough for the next phase.
- Server is enrolled as `ns3131012`.
- Tailscale IPv4: `100.125.155.110`.
- Service `tailscaled.service` is active.
- Dashboard tunnel validation remains pending until Harmony is running.

### Phase 4: Linear workflow configuration

Goal: make Linear match the upstream Harmony workflow.

Steps:

1. Use `LINEAR_API_KEY` from a private runtime environment, not from a committed file.
2. Discover the project `portal-6d90492ea04f`.
3. Discover the related Linear team/workflow.
4. List existing workflow states.
5. Create missing states:
   - `Rework`
   - `Human Review`
   - `Merging`
6. Confirm state IDs/names/types/order.
7. Avoid changing existing default statuses unless necessary.

Validation:

- Linear project has the states expected by upstream `WORKFLOW.md`.
- Harmony config `active_states` and prompt names match Linear exactly.

Current status:

- Complete for project `Portal` / team `Code Monkeys DD`.
- Created states: `Human Review`, `Rework`, `Merging`.

### Phase 5: Local Harmony build

Goal: build Harmony before customizing runtime behavior.

Steps:

1. In `/var/lib/hermes/workspaces/default/Harmony/elixir`:
   - `mise trust`
   - `mise install`
   - `mise exec -- mix setup`
   - `mise exec -- mix build`
2. Run available tests:
   - `mise exec -- mix test`
   - or documented `make all` if present.

Validation:

- Build succeeds.
- Existing tests pass or failures are understood and documented.

### Phase 6: Local workflow config for Portal

Goal: create the first runtime workflow without committing secrets.

Steps:

1. Create a local-only workflow/config path outside committed source or ignored by git.
2. Use:
   - Linear project: `portal-6d90492ea04f`
   - repo: `dezet/portal`
   - workspace root: `/var/lib/hermes/workspaces/default/harmony-workspaces`
   - logs root: `/var/lib/hermes/workspaces/default/harmony-logs`
   - port: `4000`
3. Use existing `gh` CLI credentials for first test.
4. Set conservative limits:
   - `max_concurrent_agents: 1`
   - controlled turn limit, adjusted after inspecting upstream defaults.
5. Ensure clone hook uses an auth path that supports push:
   - likely `git@github.com:dezet/portal.git` if SSH auth works,
   - otherwise use `gh`/HTTPS credential flow verified in Phase 2.

Validation:

- Workflow parses.
- No secrets in git.
- Workspace/log paths are outside the Harmony repo.

### Phase 7: Manual full-cycle test

Goal: prove the real end-to-end loop before creating a daemon.

Steps:

1. Create/select one low-risk Linear issue in `portal-6d90492ea04f`.
2. Start Harmony manually on localhost with dashboard port `4000`.
3. Open dashboard through Tailscale SSH tunnel.
4. Observe issue pickup.
5. Confirm workspace creation.
6. Confirm branch creation.
7. Confirm Codex execution.
8. Confirm tests/validation commands.
9. Confirm push and PR creation/update.
10. Confirm Linear status transitions.

Validation:

- A real low-risk issue completes the intended workflow.
- Failure modes are visible in logs/dashboard.
- No public port exposure.

### Phase 8: Service hardening

Goal: convert the proven manual run into a controlled background service.

Steps:

1. Decide initial runtime user:
   - short-term: `hermes` if it avoids auth friction,
   - preferred long-term: dedicated `harmony`.
2. Create private env file:
   - `/var/lib/hermes/.config/harmony/harmony.env`
3. Create `systemd` unit for Harmony.
4. Keep dashboard bound to localhost.
5. Enable restart on failure.
6. Verify logs with `journalctl`.
7. Document start/stop/status commands.

Validation:

- Service survives restart/failure.
- Hermes can inspect logs and manage service as agreed.
- Dashboard remains private.

### Phase 9: Dedicated Harmony identity

Goal: reduce blast radius after proof-of-life.

Steps:

1. Create dedicated `harmony` system user if not already done.
2. Create fine-grained GitHub PAT scoped to required repos.
3. Configure `gh auth login` or equivalent for `harmony`.
4. Restrict PAT permissions initially to:
   - `dezet/portal`
   - repository contents read/write
   - pull requests read/write
   - metadata read
   - checks/statuses read as needed
5. Move service to run as `harmony`.
6. Keep Hermes access through group permissions or narrow sudoers rules.

Validation:

- Full-cycle test still works under `harmony`.
- User personal GitHub credentials are no longer needed for the service.

### Phase 10: Roadmap changes

Goal: evolve Harmony after the first stable deployment.

Candidate work:

1. Multi-project Linear support:
   - now promoted from roadmap to near-term product requirement,
   - implement native `project_slugs: [...]` before long-running production deployment if possible,
   - keep multiple service instances as fallback only.
2. GitHub Issues provider.
3. GitHub Projects provider.
4. Local file provider for deterministic tests.
5. Better dashboard auth if direct Tailscale-IP access is ever desired.

Validation:

- Each provider/change has unit tests and at least one controlled integration test.

## Multi-project Implementation Plan

Goal: support multiple Linear projects in one Harmony instance and expose project-aware dashboard controls.

### M1: Baseline tests before refactor

1. Run current Harmony test suite.
2. Record existing failures, if any.
3. Avoid changing behavior until baseline is known.

Validation:

- `mix test` baseline captured.

### M2: Config model

1. Extend `elixir/lib/symphony_elixir/config/schema.ex`:
   - add `tracker.project_slugs` as array of strings,
   - keep `tracker.project_slug` for backwards compatibility,
   - normalize into one internal list getter or schema field.
2. Update config semantic validation:
   - require at least one project slug for Linear,
   - reject empty strings,
   - dedupe slugs.
3. Update tests in `elixir/test/symphony_elixir/workspace_and_config_test.exs` or nearby config tests.

Validation:

- single-project workflow still parses,
- multi-project workflow parses,
- missing project config still fails clearly.

### M3: Linear polling

1. Update `elixir/lib/symphony_elixir/linear/client.ex`:
   - fetch candidate issues across all configured project slugs,
   - fetch terminal issues across all configured project slugs,
   - preserve pagination per project,
   - attach project metadata to normalized issues if the API response provides it.
2. Update query to include project fields:
   - project id,
   - project name,
   - project slugId.
3. Ensure sorting remains deterministic across projects.

Validation:

- unit tests for multiple project pages,
- duplicate issue identifiers across projects are handled safely or explicitly ruled out.

### M4: Domain model and workspace identity

1. Extend `SymphonyElixir.Linear.Issue` / normalized issue model with project metadata:
   - `project_id`,
   - `project_name`,
   - `project_slug`.
2. Review workspace key generation:
   - current likely key is issue identifier,
   - make workspace path project-aware if needed, for example `<project-slug>/<issue-identifier>`.
3. Review active run maps and dashboard state keys:
   - issue id is probably globally unique in Linear,
   - display/grouping should still include project.

Validation:

- workspace paths do not collide across projects,
- existing single-project workspace paths either remain compatible or migration is documented.

### M5: Dashboard/API

1. Inspect `elixir/lib/symphony_elixir/status_dashboard.ex`.
2. Inspect LiveView:
   - `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
   - presenter/API modules under `elixir/lib/symphony_elixir_web/`.
3. Add project-aware presentation:
   - project selector/tab/segmented control,
   - per-project status counts,
   - issue/run list filtered by selected project,
   - all-project overview.
4. Update `/api/v1/state` shape carefully:
   - preserve existing fields if possible,
   - add `projects` collection and `project_slug` on issue/run entries.

Validation:

- dashboard tests/snapshots updated,
- API remains useful for old single-project clients,
- no UI overlap on desktop/mobile screenshots before finalizing.

### M6: Workflow prompt context

1. Add project fields to prompt rendering context:
   - `{{ issue.project_name }}`,
   - `{{ issue.project_slug }}`,
   - possibly `{{ issue.project_id }}`.
2. Update default/upstream workflow copy only if necessary.

Validation:

- prompt builder tests cover project fields.

### M7: First multi-project run strategy

1. Start with `project_slugs` containing only `portal-6d90492ea04f`.
2. Add a second Linear project only after single-project behavior passes under the new architecture.
3. Keep `max_concurrent_agents: 1` until project grouping and state transitions are proven.

Validation:

- Portal still works exactly as before.
- Adding a second project shows separate UI grouping and no cross-project workspace/log confusion.

## Progress Update

### 2026-05-30: Multi-project implementation ready for review

Completed:

- Created implementation branch:
  - `feature/multi-linear-projects`
- Implemented native multi-project Linear support in Harmony:
  - `tracker.project_slugs` is accepted as a list,
  - legacy `tracker.project_slug` remains supported,
  - when both are present, Harmony uses the de-duplicated union,
  - Linear polling now queries each configured project slug,
  - issue payloads include Linear project id/name/slug when available,
  - orchestrator status entries retain project metadata for running, retrying, and blocked work,
  - terminal/status dashboard project links handle one or many configured projects,
  - LiveView/API presenter surfaces project metadata and project counts,
  - docs/spec/tests were updated.
- Created commit:
  - `82e18da Support polling multiple Linear projects`
- Pushed branch to GitHub:
  - `origin/feature/multi-linear-projects`
- Opened PR:
  - `https://github.com/dezet/Harmony/pull/1`
- Updated PR body with current status and validation checklist.

Validation completed:

- Targeted test suite passed:
  - `mix test test/symphony_elixir/core_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/extensions_test.exs`
  - result: `144 tests, 0 failures`
- Full local quality gate passed:
  - `make all MIX='mise exec -- mix'`
  - result: setup, build, format check, lint, coverage, and Dialyzer passed
  - coverage run result: `237 tests, 0 failures, 2 skipped`
- PR body validation passed:
  - `mix pr_body.check`

Current status:

- PR #1 is open, non-draft, and waiting for human review.
- GitHub status checks are not configured/reported for this PR yet.
- Local Harmony repo worktree is clean after the commit and push.
- The original recommendation of multiple Harmony instances as the first multi-project workaround is now obsolete if PR #1 is merged.

Scope notes:

- This first multi-project version supports multiple Linear projects with one global workflow/repo/hook configuration.
- It does not yet implement richer per-project repo mapping such as:
  - project A -> repo A,
  - project B -> repo B.
- The dashboard now exposes project grouping/counts, but a richer interactive project selector/filter remains future UI work if needed.

## Proposed Steps After PR Merge

1. Sync the server checkout to the merged `main`:
   - fetch/pull `origin/main`,
   - confirm the merge commit includes `82e18da` or equivalent changes,
   - rebuild with `mise exec -- mix build`.
2. Re-run the full local gate on merged `main`:
   - `make all MIX='mise exec -- mix'`.
3. Update the private runtime workflow config:
   - replace the phase-one single value with `tracker.project_slugs`,
   - start with only `portal-6d90492ea04f` in the list,
   - keep `max_concurrent_agents: 1`.
4. Start Harmony manually before creating/changing any daemon:
   - bind dashboard to `127.0.0.1`,
   - use the existing private logs/workspace roots,
   - pass `LINEAR_API_KEY` from a private environment only.
5. Validate the dashboard/API through the Tailscale SSH tunnel:
   - confirm service boots,
   - confirm `/api/v1/state` responds,
   - confirm the dashboard shows project metadata/counts,
   - confirm no public listener is exposed.
6. Run a single-project smoke test under the new multi-project config:
   - use one low-risk Portal Linear issue,
   - confirm issue pickup, workspace creation, Codex execution, branch/PR behavior, and Linear status transitions.
7. Add a second Linear project only after Portal passes:
   - add the second slug to `tracker.project_slugs`,
   - create/confirm matching Linear workflow states for that project/team,
   - run another low-risk issue,
   - verify project grouping and no cross-project confusion in dashboard/logs.
8. Decide whether the global workflow/repo model is enough:
   - if all configured projects target `dezet/portal`, continue with this shape,
   - if projects need different repositories, plan a follow-up for per-project repo/workspace mapping.
9. After manual proof-of-life, create or update the `systemd` service:
   - keep dashboard bound to localhost,
   - store secrets in `/var/lib/hermes/.config/harmony/harmony.env` or another agreed private path,
   - document start/stop/status/journal commands.
10. After service stability, revisit dedicated credentials:
   - dedicated `harmony` system user,
   - fine-grained GitHub PAT or bot identity,
   - rotated Linear API key if strict secret hygiene is required.
