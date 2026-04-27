#!/usr/bin/env bash
# Start this Hermes checkout with the repo-local Python environment.
#
# Defaults are intentionally specific to this checkout:
#   repo root -> /Users/gh/.hermes/hermes-agent
#   python    -> /Users/gh/.hermes/hermes-agent/venv/bin/python
#
# The script can refresh dependencies when manifest files change, then start
# or restart the gateway service with the current code.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STAMP_FILE="$REPO_ROOT/.git/start-my-hermes-deps.sha256"

SKIP_DEPS=0
FORCE_DEPS=0
FOREGROUND=0
DRY_RUN=0

usage() {
  cat <<USAGE
Usage:
  scripts/start-my-hermes.sh [options]

Start the Hermes checkout at:
  ${REPO_ROOT}

By default this script:
  1. Uses the repo-local virtualenv Python.
  2. Refreshes Python and Node dependencies when dependency manifests changed.
  3. Restarts the Hermes gateway service if it is already loaded.
  4. Starts the Hermes gateway service if it is not loaded yet.

Options:
  --skip-deps     Skip dependency refresh checks entirely.
  --force-deps    Refresh dependencies even if manifests did not change.
  --foreground    Run gateway in the foreground with --replace.
  --dry-run       Print the commands that would run, without mutating state.
  -h, --help      Show this help.

Typical use:
  scripts/start-my-hermes.sh

Fast restart:
  scripts/start-my-hermes.sh --skip-deps

Foreground debugging:
  scripts/start-my-hermes.sh --foreground --skip-deps
USAGE
}

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

run() {
  log "+ $*"
  if [ "$DRY_RUN" -eq 0 ]; then
    "$@"
  fi
}

find_python_bin() {
  local candidate=""

  for candidate in "$REPO_ROOT/venv/bin/python" "$REPO_ROOT/.venv/bin/python"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

find_hash_python() {
  local candidate=""

  for candidate in "$PYTHON_BIN" "$(command -v python3 || true)" "$(command -v python || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

dependency_fingerprint() {
  local hash_python=""
  hash_python="$(find_hash_python)" || die "could not find a Python interpreter to hash dependency manifests"

  "$hash_python" - "$REPO_ROOT" <<'PY'
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
manifest_paths = [
    repo_root / "pyproject.toml",
    repo_root / "uv.lock",
    repo_root / "package.json",
    repo_root / "package-lock.json",
    repo_root / "web" / "package.json",
    repo_root / "web" / "package-lock.json",
    repo_root / "ui-tui" / "package.json",
    repo_root / "ui-tui" / "package-lock.json",
]

digest = hashlib.sha256()
for path in manifest_paths:
    digest.update(str(path.relative_to(repo_root)).encode("utf-8"))
    digest.update(b"\0")
    if path.exists():
        digest.update(path.read_bytes())
    digest.update(b"\0")

print(digest.hexdigest())
PY
}

deps_are_missing() {
  [ ! -d "$REPO_ROOT/node_modules" ] && return 0
  [ ! -d "$REPO_ROOT/web/node_modules" ] && return 0
  [ ! -d "$REPO_ROOT/ui-tui/node_modules" ] && return 0
  return 1
}

should_refresh_deps() {
  local current=""
  local previous=""

  if [ "$SKIP_DEPS" -eq 1 ]; then
    return 1
  fi

  if [ "$FORCE_DEPS" -eq 1 ]; then
    return 0
  fi

  if deps_are_missing; then
    return 0
  fi

  current="$(dependency_fingerprint)"
  if [ ! -f "$STAMP_FILE" ]; then
    return 0
  fi

  previous="$(cat "$STAMP_FILE")"
  [ "$current" != "$previous" ]
}

write_dependency_stamp() {
  local current=""

  [ "$DRY_RUN" -eq 0 ] || return 0

  current="$(dependency_fingerprint)"
  printf '%s\n' "$current" >"$STAMP_FILE"
}

refresh_dependencies() {
  log "Refreshing Hermes dependencies..."
  run "$PYTHON_BIN" -m pip install -e ".[all]"
  run npm install --silent --no-fund --no-audit --progress=false
  run npm install --silent --no-fund --no-audit --progress=false --prefix web
  run npm install --silent --no-fund --no-audit --progress=false --prefix ui-tui
  write_dependency_stamp
  log "Dependency refresh complete."
}

background_action() {
  local status_output=""

  if [ "$DRY_RUN" -eq 0 ]; then
    status_output="$("$PYTHON_BIN" -m hermes_cli.main gateway status 2>&1 || true)"
  else
    status_output="$("$PYTHON_BIN" -m hermes_cli.main gateway status 2>&1 || true)"
  fi

  if printf '%s\n' "$status_output" | grep -Fq "Gateway service is loaded"; then
    log "Gateway service is already loaded; restarting to pick up the latest code."
    run "$PYTHON_BIN" -m hermes_cli.main gateway restart
  else
    log "Gateway service is not loaded yet; starting it now."
    run "$PYTHON_BIN" -m hermes_cli.main gateway start
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    "$PYTHON_BIN" -m hermes_cli.main gateway status
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-deps)
      SKIP_DEPS=1
      shift
      ;;
    --force-deps)
      FORCE_DEPS=1
      shift
      ;;
    --foreground)
      FOREGROUND=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

cd "$REPO_ROOT"

PYTHON_BIN="$(find_python_bin)" || die "could not find a Hermes virtualenv Python under $REPO_ROOT"
command -v npm >/dev/null 2>&1 || die "npm is required but was not found in PATH"

log "Hermes repo: $REPO_ROOT"
log "Python: $PYTHON_BIN"

if [ "$SKIP_DEPS" -eq 1 ]; then
  log "Dependencies: skipping checks"
elif should_refresh_deps; then
  refresh_dependencies
else
  log "Dependencies: already up to date"
fi

if [ "$FOREGROUND" -eq 1 ]; then
  log "Starting Hermes gateway in the foreground..."
  run "$PYTHON_BIN" -m hermes_cli.main gateway run --replace
else
  log "Starting Hermes gateway service..."
  background_action
  log "Gateway logs:"
  log "  /Users/gh/.hermes/logs/gateway.log"
  log "  /Users/gh/.hermes/logs/gateway.error.log"
fi
