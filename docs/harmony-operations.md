# Harmony Operations

This runbook covers the controlled single-project Harmony runtime used for the current MVP.

## Prerequisites

- Linux host with systemd.
- Dedicated system user `harmony` with home `/var/lib/harmony`.
- GitHub access for the target repository.
- Linear API token for the target Linear project.
- Codex login for the `harmony` user through ChatGPT OAuth/device auth, `OPENAI_API_KEY`, or `CODEX_ACCESS_TOKEN`.
- Postgres available for durable runtime state.

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

Linear auth is environment-based. Confirm `/etc/harmony/harmony.env` contains a valid `LINEAR_API_KEY`:

```bash
sudo test -s /etc/harmony/harmony.env
sudo runuser -u harmony -- bash -lc 'set -a; . /etc/harmony/harmony.env; set +a; test -n "$LINEAR_API_KEY"'
```

## Manual Run

Run one controlled foreground session before systemd:

```bash
sudo runuser -u harmony -- bash -lc 'cd /var/lib/harmony/Harmony/elixir && set -a && . /etc/harmony/harmony.env && set +a && PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH" TMPDIR="$HOME/tmp" mise exec -- ./bin/symphony /etc/harmony/WORKFLOW.portal.local.md --logs-root /var/log/harmony --port 4001 --i-understand-that-this-will-be-running-without-the-usual-guardrails'
```

Dashboard/API should bind to:

```text
http://127.0.0.1:4001/
```

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
