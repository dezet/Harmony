# Harmony Operations

This runbook covers the controlled single-project Harmony runtime used for the current MVP and the
Jira intake (Jira Cloud → e-mail/SMS alert → Linear `Todo` → read-only analysis → Jira comment).
The Jira intake ships disabled and stays disabled until an operator approves the rollout.

## Prerequisites

- Linux host with systemd.
- Dedicated system user `harmony` with home `/var/lib/harmony`.
- GitHub access for the target repository.
- Linear API token for the target Linear project.
- Codex login for the `harmony` user through ChatGPT OAuth/device auth, `OPENAI_API_KEY`, or `CODEX_ACCESS_TOKEN`.
- Postgres available for durable runtime state.
- `CLOAK_KEY` in the service environment: 32 random bytes, Base64-encoded. See
  [`operations/credential-key.md`](operations/credential-key.md).

## Install

Run from the repository root:

```bash
sudo ARTIFACT_DIR="$PWD" ./install-harmony-proof-of-life.sh
```

Defaults:

- user: `harmony`
- home: `/var/lib/harmony`
- workflow: `/etc/harmony/WORKFLOW.portal.local.md`
- dashboard/API port: `4001`
- service unit: `/etc/systemd/system/harmony.service`

The installer is intentionally conservative. It runs `systemctl daemon-reload`, but it does not start
or enable the service.

## Authentication Checks

Codex device login for a ChatGPT subscription:

```bash
sudo runuser -u harmony -- bash -lc 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"; export CODEX_HOME="$HOME/.codex"; codex login --device-auth'
sudo runuser -u harmony -- bash -lc 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"; export CODEX_HOME="$HOME/.codex"; codex login status'
```

GitHub auth:

```bash
sudo runuser -u harmony -- bash -lc 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"; gh auth status'
```

Linear auth and the credential key are environment-based. Confirm `/etc/harmony/harmony.env` contains
a valid `LINEAR_API_KEY` and a `CLOAK_KEY` of 32 decoded bytes, without printing either value:

```bash
sudo test -s /etc/harmony/harmony.env
sudo runuser -u harmony -- bash -lc 'set -a; . /etc/harmony/harmony.env; set +a; test -n "$LINEAR_API_KEY"'
sudo runuser -u harmony -- bash -lc 'set -a; . /etc/harmony/harmony.env; set +a; test "$(printf %s "$CLOAK_KEY" | base64 -d | wc -c)" -eq 32'
```

## Database Migrations

Every deploy runs the migrations before the service starts. The schema changes are additive; existing
projects, runs and history stay in place. Back up the database first (see
[Backup and Restore](#backup-and-restore)).

```bash
sudo runuser -u harmony -- bash -lc 'cd /var/lib/harmony/Harmony/elixir && set -a && . /etc/harmony/harmony.env && set +a && PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH" mise exec -- mix ecto.migrate'
```

The Jira intake and Case Center migrations are:

- `20260922010000_create_intake` and `20260922010100_add_project_presentation`: the intake tables and
  the project presentation fields.
- `20260924010000_add_rule_priority_ranking`: the Jira priority order of a rule, stored when the rule is
  activated. Cases of rules activated before this migration have no ranking and show the `normal`
  priority tone. Pause and activate such a rule again to store the ranking for its new cases.
- `20260924010100_add_case_projection_indexes`: indexes of the Case Center list and Kanban.
- `20260924020000_add_project_display_name`: the project name shown in the sidebar.

Do not run down migrations against production data as an "application rollback". They only remove the
new tables on an empty test database.

## Manual Run

Run one controlled foreground session before systemd:

```bash
sudo runuser -u harmony -- bash -lc 'cd /var/lib/harmony/Harmony/elixir && set -a && . /etc/harmony/harmony.env && set +a && PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH" TMPDIR="$HOME/tmp" mise exec -- ./bin/symphony /etc/harmony/WORKFLOW.portal.local.md --logs-root /var/log/harmony --port 4001 --i-understand-that-this-will-be-running-without-the-usual-guardrails'
```

Dashboard/API should bind to:

```text
http://127.0.0.1:4001/
```

`/` opens the Case Center (Centrum spraw). The agent-run overview and the intake metrics are under
`/overview` (Diagnostyka); `/automations` and `/integrations` hold the Jira rules and connections.

## Proof-Of-Life Checklist

A controlled proof-of-life run passes only when all criteria below are true:

- Build succeeds as the `harmony` user:

  ```bash
  sudo runuser -u harmony -- bash -lc 'cd /var/lib/harmony/Harmony && PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH" make all MIX="mise exec -- mix"'
  ```

- Codex authentication succeeds as the `harmony` user:

  ```bash
  sudo runuser -u harmony -- bash -lc 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"; export CODEX_HOME="$HOME/.codex"; codex login status'
  ```

- GitHub authentication succeeds as the `harmony` user:

  ```bash
  sudo runuser -u harmony -- bash -lc 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"; gh auth status'
  ```

- Dashboard/API responds on `127.0.0.1:4001`:

  ```bash
  curl -fsS http://127.0.0.1:4001/ >/dev/null
  ```

- Linear polling sees the configured target project from `/etc/harmony/WORKFLOW.portal.local.md`.
- A test Linear issue produces a GitHub PR against the configured base branch.
- The PR remains open and unmerged for human review.
- Harmony does not direct-push to the configured base branch.
- The related Linear issue reaches `Human Review`, not `Done`.

## Systemd Rollout

After stable manual runs:

```bash
sudo systemctl start harmony
sudo systemctl status harmony
sudo journalctl -u harmony -f
```

Only after stable controlled systemd runs:

```bash
sudo systemctl enable harmony
```

Do not enable the service directly after install.

## Jira Intake

### Switches

Three runtime switches in the workflow front matter control the intake. All three default to `false`.
The runtime rereads them on every scheduler and dispatcher tick, so a change in the workflow file takes
effect without a restart. An invalid reload keeps the last valid configuration.

| Switch                   | When `false`                                                                                                                                                  |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `intake.enabled`         | No scheduled Jira scans and no new outbox claims. Effects already in flight finish and store their result. Test-send is refused.                             |
| `intake.effects_enabled` | Also blocks scans, rule activation, manual checks, reanalysis, delivery retry, Linear hold-label creation and test-send (HTTP 409 `effects_disabled`).       |
| `analysis.enabled`       | No new analyses start. Rule activation needs a working analysis profile, so no rule can be activated while it is off.                                        |

`ExecutionGate` does not depend on any switch. It refuses to start an implementation for an imported
Linear issue until an operator approves the repair of the current analysis version, also after a
restart, a retry, a database outage or a removed hold label. Diagnostyka (`/overview`) shows the state
of the three switches, the effect queues, unknown results, stale leases, the analysis pool and the last
success of every rule.

### Runtime Configuration

A complete example of the workflow front matter with the intake switched off. Values in angle
brackets and the `example.com` hosts are placeholders. Secrets never go into this file:
`tracker.api_key: $LINEAR_API_KEY` reads the token from the environment, and connection secrets live
encrypted in PostgreSQL.

```yaml
---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "<linear-project-slug>"
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 30000
workspace:
  root: /var/lib/harmony/workspaces
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex app-server
server:
  host: 127.0.0.1
  port: 4001
intake:
  enabled: false
  effects_enabled: false
  public_url: "https://harmony.example.com"
  smtp_allowed_hosts:
    - "smtp.example.com"
analysis:
  enabled: false
  model: "<analysis-model>"
  effort: medium
  max_concurrent: 1
  timeout_ms: 600000
  max_turns: 1
  max_result_bytes: 32768
---
```

Rules for these keys, enforced by `SymphonyElixir.Config.Schema`:

- `intake.enabled: true` requires `intake.public_url` to be an HTTPS URL. It is the base of the Harmony
  links in e-mails and SMS; keep it short, because the SMS link must fit in two segments.
- `intake.smtp_allowed_hosts` is the only list of SMTP relays a connection may use. Write host names in
  lower case. A connection with any other host fails with `smtp_host_not_allowed`.
- `analysis.enabled: true` requires `analysis.model`. `analysis.max_concurrent` is 1–4,
  `analysis.timeout_ms` 60000–900000, `analysis.max_turns` must be 1 and `analysis.max_result_bytes` at
  most 32768.
- The scheduler and dispatcher limits have no configuration keys: scan tick 5 s and two scans at a
  time, dispatcher tick 1 s, four I/O effects and one analysis at a time, automatic retries after
  30/120/600/1800 s.

Connections (Jira, SMTP, SMSAPI) and rules are stored in PostgreSQL and edited in `/integrations` and
`/automations`. Their secrets are encrypted with `CLOAK_KEY`, write-only in the API and UI, and never
copied into the workflow file, logs or rule snapshots.

### Required Access

Jira Cloud connection (settings `site_url`, `auth_mode`, `account_email`, `cloud_id`; secret: API
token):

- `site_url` is `https://<site>.atlassian.net`. `auth_mode: classic` calls the site URL;
  `auth_mode: scoped` calls `https://api.atlassian.com/ex/jira/<cloud_id>` and needs `cloud_id`.
  There is no automatic fallback between the two modes.
- The API token belongs to `account_email`; it is not the account password.
- The account needs Browse Projects on every project the source returns and Add Comments there
  (Harmony posts one analysis comment per case version).
- A saved-filter source needs the filter shared with the account. A board source needs read access to
  the board and its saved filter; Harmony uses the board filter, not quick filters, sprints or the
  current browser view.
- Harmony calls `GET /rest/api/3/myself`, the priority list, the filter or
  `/rest/agile/1.0/board/<id>/configuration`, `POST /rest/api/3/search/jql` and the issue comment
  endpoints. A scoped token must allow these calls: reading Jira work and users, creating comments,
  and for board sources reading Jira Software boards. Check the exact scope names in the Atlassian
  token documentation when creating the token.

Linear target (per project: the project's tracker token, or the global `LINEAR_API_KEY` fallback):

- The token must read the team, the project, workflow states and labels, and create issues in the
  target team. Harmony creates the issue with a reserved UUID (`issueCreate` with `id`) in the explicit
  `Todo` state and never uses another project's token.
- The team must have a workflow state named exactly `Todo`. Without it activation fails with 422
  `linear_todo_state_missing`; Harmony never falls back to `Backlog`.
- Every imported issue carries the hold label `harmony:analysis-only`. Pick the existing label in the
  rule form, or confirm "Utwórz etykietę ochronną w Linear" to create it; creating a label needs a token
  that may manage labels in that team. Removing the label from an issue does not lift the protection of
  an existing case.

SMTP connection (settings `host`, `port`, `tls_mode`, `username`, `from_email`, `from_name`,
`message_id_domain`; secret: SMTP password):

- `tls_mode` is `starttls` (default port 587) or `tls` (implicit TLS, usually port 465). TLS 1.2 or 1.3
  with certificate and host name verification is mandatory; plaintext is refused (`smtp_tls_required`).
- SMTP AUTH is always used. MX lookups are off, so Harmony talks only to the configured relay, which
  must be listed in `intake.smtp_allowed_hosts`.
- Each recipient gets a separate message with a stable `Message-ID`
  `<harmony.<delivery-uuid>@<message_id_domain>>`.
- The connection test opens a session (EHLO, TLS, AUTH) and closes it without DATA; it sends nothing.

SMSAPI connection (setting `sender`; secret: API token):

- The endpoint is fixed: `https://api.smsapi.pl/sms.do`, a POST form with the token in the
  `Authorization` header. The token and recipient numbers never appear in URLs or logs.
- The token must be allowed to send SMS and read the account profile. The connection test reads the
  profile (points balance) and never sends.
- `sender` is a sender name approved in the SMSAPI panel, up to 11 characters.
- Recipients are E.164 numbers, for example `+48<number>`.

### Rules

- A rule reads one source, a Jira board or a saved filter, and at least one priority chosen by Jira
  priority ID. The scan query is the source filter, the chosen priorities and `statusCategory != Done`.
- The interval is 60–86400 seconds, default 300. The next scan starts one interval after the previous
  one finished. Changing only the interval keeps deduplication; changing the source or the priorities
  disables the rule and needs a new baseline.
- Every scan reads the full current result, so it catches a priority raised on an old issue. A priority
  that appears and disappears between two scans can be missed.
- A scan stops at 10 minutes or 10000 issues with `scan_limit_exceeded`; narrow the filter then.
- `initial_policy: new_matches_only` (default): before activation a baseline scan records every issue
  that already matches, without any effect. Only issues that start matching later create cases.
- `initial_policy: include_existing`: every issue that already matches becomes a case on activation,
  with its Linear issue, alerts and analysis. The preview shows how many (`include_existing_import`)
  and activation needs an explicit confirmation.
- The policy cannot change after the first activation. A failed or partial baseline does not activate
  the rule.
- "Sprawdź teraz" runs one scan now; a scan already running returns 409.
- One Jira issue of one Jira connection creates at most one case, even when several rules match it.

### Notifications, Limits and Cost

- Alerts go out once, when a case is first detected. There are no reminders.
- A rule has up to 10 e-mail recipients and up to 10 phone numbers. E-mail and SMS are independent: a
  failure of one channel does not stop the other.
- Application limits per connection: 60 e-mails per hour and 20 SMS per hour, counted in PostgreSQL.
  Over the limit a delivery waits in `retry_wait` for the next window; nothing is dropped. Test-send
  counts toward the same limit.
- An SMS is limited to 134 UTF-16 units, at most two Unicode segments. Budget two billable segments per
  recipient per case: one case with 10 numbers can cost up to 20 segments. A longer message fails with
  `sms_message_too_long` instead of cutting the link.
- Accepted is not delivered. An e-mail marked sent means the SMTP relay accepted it; an SMS marked sent
  means SMSAPI accepted it ("Przyjęte przez SMSAPI"). Harmony has no delivery receipts.
- Transient errors are retried automatically, up to 5 attempts. 401/403 and validation errors fail with
  an operator message; 429 waits for the provider's retry time.

### Unknown Delivery Results

A delivery is `unknown` when Harmony cannot prove whether the provider accepted it: a timeout after the
message was handed over, a dropped connection, an expired lease or an unexpected response. Harmony never
resends an unknown delivery automatically. Diagnostyka shows the count ("Nieznany wynik"); the case
detail shows the affected delivery.

1. Check the provider before any retry.
   - E-mail: search the relay logs or the recipient mailbox for the `Message-ID`
     `<harmony.<delivery-uuid>@<message_id_domain>>`.
   - SMS: look up the message in the SMSAPI panel by `idx`, which is the delivery UUID.
   - Jira comment: look for a comment with the marker `Harmony analysis <case-id>/v<version>` on the
     issue.
   - Linear issue: look for the issue in the target project whose description links the Harmony case.
2. Decide.
   - The provider has it: do not retry. The delivery stays `unknown` in the history.
   - The provider does not have it: retry that one delivery.
3. Retry only an e-mail or SMS, from the case detail. The retry button opens a warning dialog with
   "Ponów mimo ryzyka". The API equivalent is `POST /api/v1/deliveries/<id>/retry` with
   `{"expected_status": "unknown", "confirm_duplicate_risk": true}` and the CSRF token.
   - The retry may send a duplicate. SMTP has no idempotency. SMSAPI deduplicates the same `idx` only
     for a limited window (error 53 then counts as accepted), so a late retry can send a second SMS.
   - A manual retry adds one attempt; it does not reset the attempt count or the history.
   - It needs `intake.effects_enabled: true` and an enabled connection; a paused delivery returns 409.
4. An unknown Linear issue or Jira comment cannot be retried from the UI; the API returns 409
   `reconciliation_required`. Do not create the Linear issue or the comment by hand. Record what the
   provider shows and escalate.

### Rollout Order

1. Back up the database and `CLOAK_KEY`, deploy and run the migrations. Keep all three switches off.
2. Confirm in Diagnostyka that the switches are off and nothing is queued.
3. Create the connections in `/integrations` and run their connection tests (read-only).
4. Create one rule for a test project; it is saved disabled. Run the preview (dry-run): it shows the
   match count and writes nothing.
5. With operator approval for the resources, recipients and SMS/analysis cost, set `intake.enabled`,
   `intake.effects_enabled` and `analysis.enabled` to `true`, with an HTTPS `intake.public_url`.
6. Activate the rule with `new_matches_only` and follow one case end to end: one Linear `Todo`, one
   e-mail and one SMS per recipient, one analysis and one Jira comment.
7. Production rules are enabled only by an operator decision; a green CI run is not an approval.

## Backup and Restore

- Back up PostgreSQL before every migration and before any rollback, for example
  `pg_dump --format=custom --file=<backup-file> <database>`. Restore with `pg_restore` into an empty
  database.
- The dump holds connection and project secrets encrypted with `CLOAK_KEY`. Back up the key separately
  in the secret manager, never next to the dump or in the repository.
- A restored database is usable only with the same `CLOAK_KEY`. Without it the stored secrets cannot be
  decrypted and must be entered again.

## Secret Rotation

- Jira API token, SMTP password, SMSAPI token: create the new credential at the provider, paste it into
  the connection in `/integrations`, run the connection test, then revoke the old credential. An empty
  secret field keeps the stored secret; clearing a secret also disables the connection.
- Project forge and tracker tokens: update them in the project form, then revoke the old ones.
- `CLOAK_KEY`: see [`operations/credential-key.md`](operations/credential-key.md#rotation). Replacing
  the key in the environment alone makes every stored secret unreadable.

## Rollback

1. Set `intake.enabled: false` and `intake.effects_enabled: false` (and `analysis.enabled: false`) in
   the runtime workflow. New scans and effects stop on the next tick; effects in flight finish.
2. Keep the database, the migrations and a binary with `ExecutionGate`. Rolling back only the UI is
   safe while the guard stays.
3. Never roll back to a binary without `ExecutionGate` while imported Linear issues exist: the old
   orchestrator would treat them as ordinary `Todo` work and start implementations. If a downgrade is
   unavoidable:
   1. Stop the orchestrator (`sudo systemctl stop harmony`).
   2. Move the imported issues (hold label `harmony:analysis-only`) out of the old binary's active scope
      in Linear by hand, and confirm it by reading them back.
   3. Only then start the old binary. Do not automate a bulk change of tickets.
4. Do not run down migrations on production data.
