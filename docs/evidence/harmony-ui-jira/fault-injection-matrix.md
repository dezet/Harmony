# Harmony UI Jira — Fault-Injection Matrix (T29.2)

Evidence for plan §10.2 of `docs/superpowers/plans/2026-09-22-harmony-ui-jira.md`.
Every row is an automated ExUnit test on the test PostgreSQL (`harmony_test`) with
stubbed Jira, Linear, SMTP, SMSAPI and model transports. Restarts touch only processes
started by the test (a test-owned supervisor, dispatcher runtime or orchestrator), never
the user service. Paths are relative to `elixir/test/symphony_elixir/`.

## Last run

- Date: 2026-09-24, branch `feature/harmony-ui-jira-m6`, base commit `878c618`.
- Command (from `elixir/`):

```bash
mise exec -- mix test \
  test/symphony_elixir/intake_fault_injection_test.exs \
  test/symphony_elixir/intake_poller_test.exs \
  test/symphony_elixir/intake_storage_test.exs \
  test/symphony_elixir/intake_linear_bridge_test.exs \
  test/symphony_elixir/intake_analysis_runner_test.exs \
  test/symphony_elixir/intake_comment_publisher_test.exs \
  test/symphony_elixir/notification_smtp_test.exs \
  test/symphony_elixir/notification_smsapi_test.exs \
  test/symphony_elixir/intake_outbox_test.exs \
  test/symphony_elixir/intake_dispatcher_test.exs \
  test/symphony_elixir/intake_actions_test.exs \
  test/symphony_elixir/intake_api_test.exs \
  test/symphony_elixir/intake_dispatcher_runtime_test.exs \
  test/symphony_elixir/intake_execution_gate_test.exs
```

- Result: `215 tests, 0 failures`, exit code 0 (seed 236655).

## Matrix

"Added" rows are new tests in `intake_fault_injection_test.exs` (T29.2). They passed on
their first run, so each was checked for sensitivity with a temporary production-code
mutation that made it fail; every mutation was reverted (see the next section).

| # | §10.2 failure point | Test (file:line) | What it asserts | Status | Last run |
| --- | --- | --- | --- | --- | --- |
| 1 | Before the qualification commit | `intake_fault_injection_test.exs:39` "a crash before the qualification commit leaves no case or effect and the next poll accepts once" | A crash while qualifying the second issue of a page, after the first case and its deliveries were written, rolls everything back: zero cases, analyses, deliveries, case events and observations; the poll scan is `failed`/`unexpected_scan_failure`. The next poll accepts both issues once (`accepted_count == 2`), a repeat poll accepts none, and each case has exactly one set of deliveries. Supporting: `intake_poller_test.exs:128` (effects switch flipped during qualification rolls back case and deliveries). | Added | Pass |
| 2 | After the commit, before the claim | `intake_fault_injection_test.exs:83` "a committed case and its deliveries survive a dispatcher restart before the first claim" | After a real poll commits the case, the `DispatcherRuntime` child of a test supervisor is killed before any tick and restarted by that supervisor. The case and all four deliveries are still `pending` with zero attempts and no lease; the restarted runtime claims Linear, e-mail and SMS once each for that case, and analysis stays queued until Linear is confirmed. | Added | Pass |
| 3 | Two pollers see an issue at the same time | `intake_fault_injection_test.exs:145` "two pollers seeing one issue at once on separate PostgreSQL connections make one case and one delivery set" | Two active rules on one Jira connection poll concurrently on two PostgreSQL backends (distinct `pg_backend_pid`), released together after both fetched the issue. Both scans succeed, accepted counts are `[0, 1]`, there is one case, one analysis and one delivery set, and the other rule records `already_linked`. Supporting: `intake_storage_test.exs:177` (concurrent raw inserts of one Jira issue leave one case). | Added | Pass |
| 4 | Linear created the issue, the response was lost | `intake_linear_bridge_test.exs:138` "a timeout after provider persistence is reconciled by reserved UUID and retry creates once"; `:189` "a second lost response is recovered by UUID without a third create"; `:306` "a process crash after Linear create is recovered by lookup before another create" | The retry looks up the reserved UUID and adopts the created issue. Exactly one create input (or two identical inputs with the same `id` after a proven absence), never a create with a new ID; the case is confirmed with the Linear identifier and URL. | Existing | Pass |
| 5 | Linear poll during create | `intake_linear_bridge_test.exs:336` "a Linear poll during create remains denied by the execution gate" | A `LinearIssueSource` poll run while the issue already exists in Linear, but before the bridge confirms it, filters it out; the gate returns `{:error, :analysis_only}` for the reserved UUID. | Existing | Pass |
| 6 | Model finished, the database write of the result failed | `intake_analysis_runner_test.exs:256` "a database failure queuing the comment rolls back results and exhausts durable retries" | With a PostgreSQL CHECK constraint rejecting the comment delivery, no result and no `jira_comment` delivery are stored; the delivery goes to `retry_wait`, then `failed` after the second model start (`attempts == 2`), with `analysis_result_persist_failed`, two `analysis_failed` events and no `analysis_completed`. | Existing | Pass |
| 7 | Result stored, comment returns 403 | `intake_fault_injection_test.exs:208` "a 403 on the Jira comment keeps the analysis result and a retry publishes without another model run" | After a real analysis, a comment POST with 403 fails the delivery (`jira_comment_permission_denied`) while the analysis stays `succeeded` with an unchanged result. A manual retry publishes the comment (`provider_id` stored) and the model is not called again; there is no new analysis delivery or version. Supporting: `intake_comment_publisher_test.exs:140` (403 POST is terminal and not reconciled). | Added | Pass |
| 8 | Comment added, the response was lost | `intake_comment_publisher_test.exs:181` "returns unknown when an accepted POST cannot be reconciled"; `:483` "reconciles every comments page after an ambiguous post before returning success"; `:595` "reconciles marker results from comment properties after an ambiguous post" | After an ambiguous POST the publisher reads every comments page and adopts the comment carrying its marker (body or `harmony.analysis` property). If it cannot confirm, the delivery is `unknown` (`jira_comment_outcome_unknown`) and no second POST is sent. Supporting: `intake_analysis_runner_test.exs:30` (timeout: one POST, then `unknown`); `intake_outbox_test.exs:393` (retrying `unknown` needs duplicate-risk confirmation and reconciliation). | Existing | Pass |
| 9 | SMTP timeout after DATA | `notification_smtp_test.exs:297` "SMTP timeout after DATA leaves the delivery unknown with no automatic resend" | The delivery becomes `unknown`/`smtp_timeout` after one attempt. Two hours later no claim happens, `recover_expired` changes nothing and the adapter is not called again. | Existing | Pass |
| 10 | SMSAPI duplicate idx | `notification_smsapi_test.exs:130` "duplicate idx (code 53) means the SMS was already accepted and nothing new is sent"; `:242` "an uncertain SMS stays unknown; a confirmed retry reuses the idx and code 53 completes it" | Code 53 counts as accepted. The confirmed retry sends the same `idx` (the delivery ID) with `check_idx=1`, the delivery becomes `succeeded`, and no request with a new idx is made. | Existing | Pass |
| 11 | One channel failed | `intake_fault_injection_test.exs:244` "a definitively failed SMS channel does not stop e-mail or the analysis" | SMSAPI 401 fails the SMS delivery (`sms_auth_failed`). E-mail to the same case is still sent, the real analysis runner completes and queues the Jira comment; final statuses are `sms: failed`, `email`, `analysis`, `linear_create: succeeded`, `jira_comment: pending`. Supporting: `notification_smsapi_test.exs:298` (an `unknown` SMS does not block e-mail, Linear or analysis). | Added | Pass |
| 12 | Lease expires, the old worker returns | `intake_outbox_test.exs:194` "expired write-capable leases become unknown while analysis uses its recovery path"; `intake_dispatcher_test.exs:110` "an expired adapter lease cannot overwrite a concurrent terminal result"; `intake_analysis_runner_test.exs:633` "a late result after lease loss cannot persist an analysis or comment" | A completion with the expired token is `{:error, :stale_lease}`. Recovery turns write-capable deliveries into `unknown` and re-queues analysis. A late adapter result cannot overwrite a newer terminal state, and a late analysis result stores no result and no comment delivery. Supporting: `intake_outbox_test.exs:88` (stale token CAS). | Existing | Pass |
| 13 | Rule change saved during baseline | `intake_poller_test.exs:406` "a config change during a paginated scan cancels the stale generation" | A `Rules.patch` of the source between baseline pages returns `{:error, :stale_generation}`. The rule stays disabled with no `baseline_generation` or `last_success_at`, and the scan is `cancelled` with `stale_generation`. | Existing | Pass |
| 14 | Approve and reanalyze at the same time | `intake_actions_test.exs:299` "approve and reanalyze race on independent PostgreSQL connections with one durable winner"; `intake_api_test.exs:855` "approve and reanalyze of the same version: one wins, the other is 409" | On two PostgreSQL backends exactly one action succeeds and the other gets `stale_version`/`repair_already_approved`; the stored case holds only one outcome. Over HTTP the statuses are `[200, 409]` or `[202, 409]`. | Existing | Pass |
| 15 | Database unavailable during dispatch | `intake_fault_injection_test.exs:289` "an unreadable database during orchestrator dispatch keeps an imported Todo out of implementation"; `intake_dispatcher_runtime_test.exs:255` "an unavailable database during dispatch keeps no in-memory work and recovers from the outbox"; `intake_execution_gate_test.exs:116` "removed labels, unlinked markers, foreign projects, and database failures deny" | Orchestrator (added): an imported Todo without label or marker, whose Repo calls fail, is not started; the log shows `reason=:database_unavailable` and the orchestrator stays alive. Outbox: a connection error keeps the delivery `pending` with nothing held in memory, and the next tick with the database back dispatches it. Gate: a failing repository gives `database_unavailable`, never "no case". | Added + existing | Pass |
| 16 | Intake/effects disabled after a restart | `intake_dispatcher_runtime_test.exs:153` "intake and effects disabled in the runtime config after a restart start no new effects"; `intake_execution_gate_test.exs:87` "gate remains active after restart while intake is disabled" | A runtime started with switches read from the disabled config starts no workers and calls no adapter; the delivery stays `pending`. An orchestrator restarted with intake disabled still does not start the imported Todo, and the gate returns `analysis_only`. | Existing | Pass |

## Sensitivity of the added tests

Each mutation was applied to production code, the single test was run, and the file was
restored with `git checkout -- <file>`. `git status` showed no production change afterwards.

| Test | Temporary mutation | Result |
| --- | --- | --- |
| `:39` (row 1) | `Intake.Matcher.accumulate_issue/6` rescues an exception and commits the page up to that point | Fails: the scan returns `{:ok, ...}` instead of `{:error, :unexpected_scan_failure}` |
| `:83` (row 2) | `Intake.Matcher.insert_deliveries/4` drops the e-mail and SMS deliveries from the commit | Fails: after the restart only `analysis` and `linear_create` are pending |
| `:145` (row 3) | `Intake.Matcher.accept_issue/5` skips `advisory_lock!/2` | Fails: one concurrent scan returns `{:error, changeset}` (unique constraint) instead of linking the existing case |
| `:208` (row 7) | `Intake.Outbox` treats a `failed` delivery as not manually retryable | Fails: `manual_retry/2` returns `{:error, :not_retryable}` |
| `:244` (row 11) | `Intake.Outbox.fail/4` also fails the other pending deliveries of the case | Fails: the e-mail dispatch finds nothing to claim (`:empty`) |
| `:289` (row 15) | `Intake.ExecutionGate` treats a database error as "no case" | Fails: the implementation runner starts for the imported Todo |

## Limits

- Row 15 (orchestrator): the database is unavailable because the orchestrator process is
  not allowed into the test's SQL sandbox connection. Every Repo call it makes raises an
  ownership error. This is a real Repo failure, not a stub repository, but it is not a
  PostgreSQL server outage. Stopping the shared test database is out of scope, because
  this procedure must not stop databases.
- Rows 2, 11 and 7 dispatch through the outbox with stubbed transports. Rows 1, 2, 7 and 11
  write inside the SQL sandbox, so their "commit" is a savepoint of the test transaction.
  Rows 3 and 14 commit for real on independent PostgreSQL connections and clean up their
  committed fixtures in `on_exit`.
- Timing-sensitive existing tests: at host load averages of about 12–27, unchanged tests in
  `intake_dispatcher_runtime_test.exs` (`:43`, `:130`, `:255`) and
  `notification_smsapi_test.exs:345` failed intermittently. The causes were default 100 ms
  `assert_receive` windows, an `on_exit` stop racing an exited runtime, and deliveries due at
  the wall clock instead of the claim clock. These tests were then fixed (test code only):
  explicit 2 s positive receive windows, a stop that tolerates an exited process, and
  `next_attempt_at` derived from the claim clock. Both files then passed
  `--repeat-until-failure 20` with `--max-cases 1` and `--max-cases 32`, and 10 repeats at a
  load average of about 38–71.
