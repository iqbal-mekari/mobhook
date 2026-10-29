#!/usr/bin/env bash
# Tiny assertion helpers for the release-script tests (bash 3.2 compatible).
# Source this file; it never touches the network or real GitHub.

PASS_COUNT=0
FAIL_COUNT=0

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/.github/scripts"
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '  ok   %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  FAIL %s\n' "$1"
  if [ -n "${2:-}" ]; then
    printf '       %s\n' "$2"
  fi
}

# expect_ok NAME CMD...   : command must exit 0
expect_ok() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$name"
  else
    fail "$name" "expected success"
  fi
}

# expect_fail NAME CMD... : command must exit non-zero
expect_fail() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$name" "expected failure"
  else
    pass "$name"
  fi
}

# assert_contains NAME HAYSTACK NEEDLE (fixed string)
assert_contains() {
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1" "missing: $3" ;;
  esac
}

# assert_not_contains NAME HAYSTACK NEEDLE (fixed string)
assert_not_contains() {
  case "$2" in
    *"$3"*) fail "$1" "unexpected: $3" ;;
    *) pass "$1" ;;
  esac
}

# Isolated git environment: no user/global config, fixed identity.
git_isolate() {
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.invalid"
  export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.invalid"
}

finish() {
  printf '%s: %d passed, %d failed\n' "$1" "$PASS_COUNT" "$FAIL_COUNT"
  [ "$FAIL_COUNT" -eq 0 ]
}
