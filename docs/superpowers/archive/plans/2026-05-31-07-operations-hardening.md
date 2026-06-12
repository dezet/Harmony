# Operations Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the dedicated `harmony` runtime repeatable and observable, with clear sandbox diagnostics, idempotent setup, and safe systemd rollout guidance.

**Architecture:** Add runtime diagnostics modules and dashboard/API projection before changing install behavior. Keep the existing proof-of-life artifacts as source material, then move them into documented, idempotent operational paths.

**Tech Stack:** Elixir diagnostics, Phoenix presenter/dashboard, bash installer, systemd unit, ExUnit.

---

## File Structure

- Create: `elixir/lib/symphony_elixir/diagnostics/sandbox.ex`
- Create: `elixir/lib/symphony_elixir/diagnostics/runtime.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Modify: `install-harmony-proof-of-life.sh`
- Modify: `harmony.service`
- Modify: `elixir/README.md`
- Create: `docs/harmony-operations.md`
- Test: `elixir/test/symphony_elixir/diagnostics_test.exs`
- Test: `elixir/test/symphony_elixir/extensions_test.exs`

## Tasks

### Task 1: Add Sandbox Diagnostics

**Files:**
- Create: `elixir/lib/symphony_elixir/diagnostics/sandbox.ex`
- Test: `elixir/test/symphony_elixir/diagnostics_test.exs`

- [ ] **Step 1: Write diagnostics tests**

```elixir
defmodule SymphonyElixir.DiagnosticsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Diagnostics.Sandbox

  test "reports bubblewrap missing" do
    executable = fn "bwrap" -> nil end
    read_file = fn _ -> {:error, :enoent} end

    report = Sandbox.report(executable: executable, read_file: read_file, thread_sandbox: "danger-full-access")

    refute report.bubblewrap_available
    assert report.thread_sandbox == "danger-full-access"
    assert report.posture == "danger_full_access"
  end

  test "reports restricted unprivileged user namespaces" do
    executable = fn "bwrap" -> "/usr/bin/bwrap" end
    read_file = fn "/proc/sys/kernel/apparmor_restrict_unprivileged_userns" -> {:ok, "1\n"} end

    report = Sandbox.report(executable: executable, read_file: read_file, thread_sandbox: "workspace-write")

    assert report.bubblewrap_available
    assert report.apparmor_restrict_unprivileged_userns == 1
  end
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/diagnostics_test.exs
```

Expected: missing diagnostics module.

- [ ] **Step 3: Implement sandbox report**

Create a struct with:

- `bubblewrap_available`
- `apparmor_restrict_unprivileged_userns`
- `thread_sandbox`
- `turn_sandbox_type`
- `posture`
- `warnings`

Default file reads:

- `/proc/sys/kernel/apparmor_restrict_unprivileged_userns`

Posture:

- `"danger_full_access"` when thread sandbox is `danger-full-access` or turn sandbox type is `dangerFullAccess`.
- `"workspace_sandbox_requested"` for workspace-write modes.

- [ ] **Step 4: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/diagnostics_test.exs
git add elixir/lib/symphony_elixir/diagnostics elixir/test/symphony_elixir/diagnostics_test.exs
git commit -m "feat(diagnostics): report sandbox posture"
```

Expected: tests pass.

### Task 2: Expose Diagnostics In Snapshot/API/Dashboard

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Test: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: Add API projection test**

Extend state payload test to include:

```elixir
assert state_payload["runtime"]["sandbox"]["posture"] in ["danger_full_access", "workspace_sandbox_requested"]
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/extensions_test.exs
```

Expected: payload has no runtime sandbox section.

- [ ] **Step 3: Add snapshot diagnostics**

In the orchestrator snapshot handler, include:

```elixir
runtime: %{
  sandbox: SymphonyElixir.Diagnostics.Sandbox.report(
    thread_sandbox: Config.settings!().codex.thread_sandbox,
    turn_sandbox_policy: Config.codex_turn_sandbox_policy()
  )
}
```

Project the report through `Presenter.state_payload/2`.

- [ ] **Step 4: Add dashboard band**

Render a compact `Runtime` section showing:

- sandbox posture,
- bubblewrap availability,
- AppArmor userns restriction value,
- warnings.

- [ ] **Step 5: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/extensions_test.exs test/symphony_elixir/diagnostics_test.exs
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/lib/symphony_elixir_web/presenter.ex elixir/lib/symphony_elixir_web/live/dashboard_live.ex elixir/test/symphony_elixir/extensions_test.exs
git commit -m "feat(diagnostics): expose runtime sandbox status"
```

Expected: tests pass.

### Task 3: Make Installer Idempotence Explicit

**Files:**
- Modify: `install-harmony-proof-of-life.sh`
- Modify: `harmony.service`
- Create: `docs/harmony-operations.md`

- [ ] **Step 1: Add shellcheck-friendly structure**

Refactor installer into named functions:

- `ensure_system_user`
- `ensure_directories`
- `install_workflow`
- `install_runtime_tools`
- `install_codex`
- `build_harmony`
- `install_systemd_unit`
- `print_manual_run_instructions`

Keep existing defaults:

- user `harmony`
- home `/var/lib/harmony`
- port `4001`
- workflow `/etc/harmony/WORKFLOW.portal.local.md`

- [ ] **Step 2: Add explicit no-enable behavior**

Ensure the script only runs:

```bash
systemctl daemon-reload
```

Do not run:

```bash
systemctl enable harmony
systemctl start harmony
```

Print the manual commands after successful install.

- [ ] **Step 3: Add operations doc**

Create `docs/harmony-operations.md` with:

- prerequisites,
- install command,
- manual run command,
- Codex OAuth/device login commands,
- GitHub auth check,
- Linear auth check,
- `systemctl start harmony`,
- `systemctl status harmony`,
- `journalctl -u harmony -f`,
- rule that `systemctl enable harmony` happens only after stable manual runs.

- [ ] **Step 4: Validate script syntax**

Run:

```bash
bash -n install-harmony-proof-of-life.sh
systemd-analyze verify harmony.service
```

Expected:

- `bash -n` exits 0.
- `systemd-analyze verify` exits 0 or reports only environment-specific missing-user warnings. Record the exact output.

- [ ] **Step 5: Commit**

```bash
git add install-harmony-proof-of-life.sh harmony.service docs/harmony-operations.md
git commit -m "docs(ops): document controlled harmony startup"
```

### Task 4: Runtime Port And Config Cleanup

**Files:**
- Modify: `elixir/lib/symphony_elixir/cli.ex`
- Modify: `elixir/lib/symphony_elixir/config.ex`
- Test: `elixir/test/symphony_elixir/cli_test.exs`
- Test: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

- [ ] **Step 1: Add CLI/database clarity tests**

Add tests that assert:

- `--port 4001` overrides workflow `server.port`.
- invalid negative port returns usage.
- `Config.server_port/0` returns workflow port when no override exists.

- [ ] **Step 2: Run tests**

```bash
cd elixir
mix test test/symphony_elixir/cli_test.exs test/symphony_elixir/workspace_and_config_test.exs
```

Expected: existing behavior likely passes; update docs if tests confirm no code change is needed.

- [ ] **Step 3: Commit tests/docs**

```bash
git add elixir/test/symphony_elixir/cli_test.exs elixir/test/symphony_elixir/workspace_and_config_test.exs elixir/README.md
git commit -m "test(config): cover runtime port overrides"
```

### Task 5: Manual Proof-Of-Life Runbook

**Files:**
- Modify: `docs/harmony-operations.md`

- [ ] **Step 1: Add checklist**

Add a checklist with exact pass criteria:

- `make all MIX='mise exec -- mix'` passes.
- `codex login status` succeeds as `harmony`.
- `gh auth status` succeeds as `harmony`.
- dashboard binds `127.0.0.1:4001`.
- Linear polling sees target project.
- test issue produces PR to configured base branch.
- PR remains unmerged.
- Linear issue reaches `Human Review`.

- [ ] **Step 2: Commit**

```bash
git add docs/harmony-operations.md
git commit -m "docs(ops): add proof of life checklist"
```

### Task 6: Validate Operations Hardening

- [ ] **Step 1: Run targeted tests**

```bash
cd elixir
mix test test/symphony_elixir/diagnostics_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/cli_test.exs
```

Expected: all pass.

- [ ] **Step 2: Validate shell assets**

```bash
bash -n install-harmony-proof-of-life.sh
systemd-analyze verify harmony.service
```

Expected: shell syntax passes and systemd verification has no unit syntax errors.
