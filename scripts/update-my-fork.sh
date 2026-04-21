#!/usr/bin/env bash
# Update this personal Hermes fork from the official upstream repository.
#
# Defaults are intentionally specific to this checkout:
#   origin   -> git@github.com:biubiuHui/hermes-agent.git
#   upstream -> git@github.com:NousResearch/hermes-agent.git
#
# The script refuses to run with uncommitted changes. Commit or stash first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ORIGIN_URL="${HERMES_FORK_REMOTE:-git@github.com:biubiuHui/hermes-agent.git}"
UPSTREAM_URL="${HERMES_UPSTREAM_REMOTE:-git@github.com:NousResearch/hermes-agent.git}"
MAIN_BRANCH="${HERMES_MAIN_BRANCH:-main}"

RUN_TESTS=1
PUSH_CHANGES=1
ASSUME_YES=0
DRY_RUN=0

usage() {
  cat <<USAGE
Usage:
  scripts/update-my-fork.sh [options]

Update this local Hermes checkout from the official upstream repo, merge
upstream/${MAIN_BRANCH} into your fork's ${MAIN_BRANCH}, run the focused gateway
tests, and push ${MAIN_BRANCH} back to your fork.

Default remotes:
  origin:   ${ORIGIN_URL}
  upstream: ${UPSTREAM_URL}

Options:
  --yes              Run without interactive confirmation.
  --skip-tests       Skip the focused gateway pytest run.
  --no-push          Do not push ${MAIN_BRANCH} to origin after merging.
  --dry-run          Print commands without running mutating git operations.
  --origin URL       Override the fork remote URL.
  --upstream URL     Override the official upstream remote URL.
  --branch NAME      Override the branch name, default: ${MAIN_BRANCH}.
  -h, --help         Show this help.

Typical use:
  scripts/update-my-fork.sh

Automated use:
  scripts/update-my-fork.sh --yes
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

confirm() {
  local prompt="$1"

  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi

  if [ ! -t 0 ]; then
    die "$prompt Use --yes to run non-interactively."
  fi

  local response=""
  printf '%s [y/N] ' "$prompt"
  read -r response
  case "$response" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --skip-tests)
      RUN_TESTS=0
      shift
      ;;
    --no-push)
      PUSH_CHANGES=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --origin)
      [ "$#" -ge 2 ] || die "--origin requires a URL"
      ORIGIN_URL="$2"
      shift 2
      ;;
    --upstream)
      [ "$#" -ge 2 ] || die "--upstream requires a URL"
      UPSTREAM_URL="$2"
      shift 2
      ;;
    --branch)
      [ "$#" -ge 2 ] || die "--branch requires a branch name"
      MAIN_BRANCH="$2"
      shift 2
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

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$REPO_ROOT is not a git repository"

ensure_remote() {
  local name="$1"
  local expected_url="$2"
  local current_url=""

  if current_url="$(git remote get-url "$name" 2>/dev/null)"; then
    if [ "$current_url" = "$expected_url" ]; then
      return 0
    fi

    confirm "Remote '$name' is '$current_url'. Change it to '$expected_url'?" \
      || die "remote '$name' was not changed"
    run git remote set-url "$name" "$expected_url"
  else
    confirm "Remote '$name' is missing. Add '$expected_url'?" \
      || die "remote '$name' was not added"
    run git remote add "$name" "$expected_url"
  fi
}

require_clean_worktree() {
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die "working tree has uncommitted changes. Commit or stash them before updating."
  fi

  if [ -n "$(git ls-files --others --exclude-standard)" ]; then
    die "working tree has untracked files. Commit, stash, or remove them before updating."
  fi
}

run_tests() {
  local python_bin=""

  for candidate in "$REPO_ROOT/venv/bin/python" "$REPO_ROOT/.venv/bin/python" "$HOME/.hermes/hermes-agent/venv/bin/python"; do
    if [ -x "$candidate" ]; then
      python_bin="$candidate"
      break
    fi
  done

  [ -n "$python_bin" ] || die "could not find a Hermes virtualenv Python"

  run "$python_bin" -m pytest \
    tests/gateway/test_session_env.py \
    tests/gateway/test_restart_drain.py \
    -q
}

log "Hermes repo: $REPO_ROOT"
log "Target branch: $MAIN_BRANCH"
log "Fork remote: $ORIGIN_URL"
log "Official upstream: $UPSTREAM_URL"

if [ "$RUN_TESTS" -eq 1 ]; then
  log "Tests: focused gateway tests enabled"
else
  log "Tests: skipped"
fi

if [ "$PUSH_CHANGES" -eq 1 ]; then
  log "Push: enabled"
else
  log "Push: disabled"
fi

confirm "Continue updating your Hermes fork?" || die "update cancelled"

ensure_remote origin "$ORIGIN_URL"
ensure_remote upstream "$UPSTREAM_URL"
require_clean_worktree

run git fetch origin "$MAIN_BRANCH:refs/remotes/origin/$MAIN_BRANCH"
run git fetch upstream "$MAIN_BRANCH:refs/remotes/upstream/$MAIN_BRANCH"

if [ "$DRY_RUN" -eq 0 ]; then
  git show-ref --verify --quiet "refs/heads/$MAIN_BRANCH" \
    || die "local branch '$MAIN_BRANCH' does not exist"
fi

run git switch "$MAIN_BRANCH"
run git merge --ff-only "origin/$MAIN_BRANCH"

log "Merging official upstream into your fork branch..."
if ! run git merge --no-edit "upstream/$MAIN_BRANCH"; then
  cat >&2 <<EOF

Merge conflicts were left in the working tree.
Resolve them, then run:
  git add <files>
  git commit
  scripts/update-my-fork.sh --skip-tests --no-push

EOF
  exit 1
fi

if [ "$RUN_TESTS" -eq 1 ]; then
  run_tests
fi

if [ "$PUSH_CHANGES" -eq 1 ]; then
  run git push origin "$MAIN_BRANCH"
else
  log "Skipped push. Push later with: git push origin $MAIN_BRANCH"
fi

log "Update flow finished."
