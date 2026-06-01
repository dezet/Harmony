#!/usr/bin/env bash
set -euo pipefail

HARMONY_USER="${HARMONY_USER:-harmony}"
HARMONY_HOME="${HARMONY_HOME:-/var/lib/harmony}"
HARMONY_REPO="${HARMONY_REPO:-https://github.com/dezet/Harmony.git}"
HARMONY_BRANCH="${HARMONY_BRANCH:-main}"
HARMONY_PORT="${HARMONY_PORT:-4001}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$SCRIPT_DIR}"
ENV_FILE="/etc/harmony/harmony.env"
WORKFLOW_FILE="/etc/harmony/WORKFLOW.portal.local.md"
SERVICE_FILE="/etc/systemd/system/harmony.service"

sudo_user_home() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    getent passwd "$SUDO_USER" | cut -d: -f6 || true
  fi
}

codex_source_bin() {
  local sudo_home
  sudo_home="$(sudo_user_home)"

  if command -v codex >/dev/null 2>&1; then
    command -v codex
  elif [ -n "$sudo_home" ] && [ -x "$sudo_home/.local/bin/codex" ]; then
    printf '%s\n' "$sudo_home/.local/bin/codex"
  fi
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root, for example: sudo ARTIFACT_DIR=$ARTIFACT_DIR $0" >&2
    exit 1
  fi
}

install_system_package_if_available() {
  local package="$1"

  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
  else
    echo "WARNING: apt-get was not found. Install system package '$package' manually." >&2
  fi
}

ensure_system_user() {
  if ! id "$HARMONY_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$HARMONY_HOME" --shell /bin/bash "$HARMONY_USER"
  fi
}

ensure_directories() {
  install -d -m 0755 /etc/harmony
  install -d -m 0755 /var/log/harmony
  install -d -m 0755 -o "$HARMONY_USER" -g "$HARMONY_USER" "$HARMONY_HOME"
  install -d -m 0755 -o "$HARMONY_USER" -g "$HARMONY_USER" "$HARMONY_HOME/workspaces"
  install -d -m 0755 -o "$HARMONY_USER" -g "$HARMONY_USER" "$HARMONY_HOME/tmp"
  install -d -m 0700 -o "$HARMONY_USER" -g "$HARMONY_USER" "$HARMONY_HOME/.codex"
  chown "$HARMONY_USER:$HARMONY_USER" /var/log/harmony

  find /tmp -maxdepth 1 -type d -name 'specs-check-test-*' -exec rm -rf {} +
}

upsert_env_var() {
  local key="$1"
  local value="$2"
  local tmp_file

  tmp_file="$(mktemp)"
  if grep -q "^${key}=" "$ENV_FILE"; then
    awk -v key="$key" -v value="$value" '
      $0 ~ "^" key "=" {
        print key "=" value
        next
      }
      { print }
    ' "$ENV_FILE" >"$tmp_file"
  else
    cat "$ENV_FILE" >"$tmp_file"
    printf '%s=%s\n' "$key" "$value" >>"$tmp_file"
  fi

  cat "$tmp_file" >"$ENV_FILE"
  rm -f "$tmp_file"
}

ensure_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    touch "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    chown "$HARMONY_USER:$HARMONY_USER" "$ENV_FILE"
    {
      echo "# Replace placeholder values before starting Harmony."
      printf 'LINEAR_API_KEY=%s\n' "${LINEAR_API_KEY:-replace-me}"
      [ -n "${OPENAI_API_KEY:-}" ] && printf 'OPENAI_API_KEY=%s\n' "$OPENAI_API_KEY"
      [ -n "${CODEX_ACCESS_TOKEN:-}" ] && printf 'CODEX_ACCESS_TOKEN=%s\n' "$CODEX_ACCESS_TOKEN"
    } >"$ENV_FILE"
  fi

  [ -n "${LINEAR_API_KEY:-}" ] && upsert_env_var "LINEAR_API_KEY" "$LINEAR_API_KEY"
  [ -n "${OPENAI_API_KEY:-}" ] && upsert_env_var "OPENAI_API_KEY" "$OPENAI_API_KEY"
  [ -n "${CODEX_ACCESS_TOKEN:-}" ] && upsert_env_var "CODEX_ACCESS_TOKEN" "$CODEX_ACCESS_TOKEN"

  chmod 0600 "$ENV_FILE"
  chown "$HARMONY_USER:$HARMONY_USER" "$ENV_FILE"
}

install_workflow() {
  local tmp_workflow

  tmp_workflow="$(mktemp)"
  awk -v port="$HARMONY_PORT" '
    $0 ~ /^  port: [0-9]+$/ {
      print "  port: " port
      next
    }
    { print }
  ' "$ARTIFACT_DIR/WORKFLOW.portal.local.md" >"$tmp_workflow"
  install -m 0644 -o "$HARMONY_USER" -g "$HARMONY_USER" "$tmp_workflow" "$WORKFLOW_FILE"
  rm -f "$tmp_workflow"
}

sync_harmony_repo() {
  if [ ! -d "$HARMONY_HOME/Harmony/.git" ]; then
    runuser -u "$HARMONY_USER" -- git clone "$HARMONY_REPO" "$HARMONY_HOME/Harmony"
  fi

  runuser -u "$HARMONY_USER" -- bash -lc "
set -euo pipefail
cd '$HARMONY_HOME/Harmony'
git fetch origin '$HARMONY_BRANCH'
git checkout '$HARMONY_BRANCH'
git reset --hard 'origin/$HARMONY_BRANCH'
git status --short --branch
"
}

install_runtime_tools() {
  if ! command -v bwrap >/dev/null 2>&1; then
    install_system_package_if_available bubblewrap
  fi

  runuser -u "$HARMONY_USER" -- bash -lc '
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
if ! command -v mise >/dev/null 2>&1; then
  curl https://mise.run | sh
fi
if ! command -v rustup >/dev/null 2>&1; then
  curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
fi
'
}

install_codex() {
  local source_bin
  local codex_real_bin
  local codex_release_dir

  if runuser -u "$HARMONY_USER" -- bash -lc 'PATH="$HOME/.local/bin:$PATH" command -v codex >/dev/null 2>&1'; then
    return 0
  fi

  source_bin="$(codex_source_bin || true)"
  if [ -z "$source_bin" ] || [ ! -x "$(readlink -f "$source_bin")" ]; then
    echo "WARNING: codex CLI was not found. Install codex for $HARMONY_USER before the manual proof-of-life run." >&2
    return 0
  fi

  codex_real_bin="$(readlink -f "$source_bin")"
  codex_release_dir="$(cd "$(dirname "$codex_real_bin")/.." && pwd -P)"
  install -d -m 0755 -o "$HARMONY_USER" -g "$HARMONY_USER" "$HARMONY_HOME/.local/bin"

  if [ -x "$codex_release_dir/codex-resources/bwrap" ]; then
    rm -rf "$HARMONY_HOME/.local/share/codex-standalone"
    install -d -m 0755 -o "$HARMONY_USER" -g "$HARMONY_USER" "$HARMONY_HOME/.local/share/codex-standalone"
    cp -a "$codex_release_dir/." "$HARMONY_HOME/.local/share/codex-standalone/"
    chown -R "$HARMONY_USER:$HARMONY_USER" "$HARMONY_HOME/.local/share/codex-standalone"
    ln -sfn "$HARMONY_HOME/.local/share/codex-standalone/bin/codex" "$HARMONY_HOME/.local/bin/codex"
  else
    install -m 0755 -o "$HARMONY_USER" -g "$HARMONY_USER" "$codex_real_bin" "$HARMONY_HOME/.local/bin/codex"
  fi
}

configure_github_auth() {
  if [ -n "${HARMONY_GH_TOKEN:-}" ]; then
    printf "%s" "$HARMONY_GH_TOKEN" | runuser -u "$HARMONY_USER" -- bash -lc '
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
gh auth login --with-token
gh auth setup-git
'
  fi
}

configure_codex_auth() {
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    printf "%s" "$OPENAI_API_KEY" | runuser -u "$HARMONY_USER" -- bash -lc '
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
codex login --with-api-key
'
  elif [ -n "${CODEX_ACCESS_TOKEN:-}" ]; then
    printf "%s" "$CODEX_ACCESS_TOKEN" | runuser -u "$HARMONY_USER" -- bash -lc '
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
codex login --with-access-token
'
  fi
}

build_harmony() {
  runuser -u "$HARMONY_USER" -- bash -lc '
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
cd "$HOME/Harmony/elixir"
mise trust
mise install
mise exec -- mix local.hex --force
mise exec -- mix local.rebar --force
mise exec -- mix setup
mise exec -- mix build
make all MIX="mise exec -- mix"
'
}

install_systemd_unit() {
  local tmp_service

  tmp_service="$(mktemp)"
  awk -v port="$HARMONY_PORT" '
    /^ExecStart=/ {
      gsub(/--port [0-9]+/, "--port " port)
    }
    { print }
  ' "$ARTIFACT_DIR/harmony.service" >"$tmp_service"
  install -m 0644 "$tmp_service" "$SERVICE_FILE"
  rm -f "$tmp_service"
  systemctl daemon-reload
}

print_manual_run_instructions() {
  cat <<EOF
Installed Harmony proof-of-life assets.

Manual run:
  runuser -u $HARMONY_USER -- bash -lc 'cd $HARMONY_HOME/Harmony/elixir && set -a && . $ENV_FILE && set +a && PATH="\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH" TMPDIR="\$HOME/tmp" mise exec -- ./bin/symphony $WORKFLOW_FILE --logs-root /var/log/harmony --port $HARMONY_PORT --i-understand-that-this-will-be-running-without-the-usual-guardrails'

Codex OAuth/device login for a ChatGPT subscription, if you did not pass OPENAI_API_KEY or CODEX_ACCESS_TOKEN:
  runuser -u $HARMONY_USER -- bash -lc 'export PATH="\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH"; export CODEX_HOME="\$HOME/.codex"; codex login --device-auth'
  runuser -u $HARMONY_USER -- bash -lc 'export PATH="\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH"; export CODEX_HOME="\$HOME/.codex"; codex login status'

After controlled manual success:
  systemctl start harmony
  systemctl status harmony
  journalctl -u harmony -f

Enable only after multiple stable controlled runs:
  systemctl enable harmony
EOF
}

main() {
  require_root
  ensure_system_user
  ensure_directories
  ensure_env_file
  install_workflow
  sync_harmony_repo
  install_runtime_tools
  install_codex
  configure_github_auth
  configure_codex_auth
  build_harmony
  install_systemd_unit
  print_manual_run_instructions
}

main "$@"
