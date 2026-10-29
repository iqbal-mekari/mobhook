#!/usr/bin/env bash
# Validate a release tag before anything is built or published.
#
# Usage:  RELEASE_TAG=v1.2.3 validate-release-tag.sh [--format-only]
#
# Environment:
#   RELEASE_TAG   (required) tag name. Read from the environment only; it is
#                 never interpolated into code or used unquoted.
#   CARGO_TOML    path to Cargo.toml          (default: Cargo.toml)
#   MAIN_REF      ref the tagged commit must be an ancestor of
#                 (default: origin/main)
#   COMMIT        commit to check             (default: HEAD)
#
# Checks (all must pass):
#   1. tag matches strict SemVer 2.0.0 with a leading "v" (no build metadata)
#   2. tag version equals the [package] version in Cargo.toml
#   3. COMMIT is an ancestor of (or equal to) MAIN_REF
# --format-only runs check 1 only.
set -euo pipefail

SEMVER_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$'

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

format_only=0
if [ "${1:-}" = "--format-only" ]; then
  format_only=1
elif [ "$#" -gt 0 ]; then
  fail "unknown argument"
fi

tag="${RELEASE_TAG-}"
[ -n "$tag" ] || fail "RELEASE_TAG is empty or unset"

# [[ =~ ]] matches the whole string, so an embedded newline cannot sneak past.
# Never print the raw value: it is untrusted (could hold control characters).
if ! [[ "$tag" =~ $SEMVER_RE ]]; then
  fail "release tag is not strict SemVer of the form vMAJOR.MINOR.PATCH[-prerelease]"
fi

if [ "$format_only" -eq 1 ]; then
  printf 'ok: tag format valid (%s)\n' "$tag"
  exit 0
fi

version="${tag#v}"

cargo_toml="${CARGO_TOML:-Cargo.toml}"
[ -f "$cargo_toml" ] || fail "Cargo.toml not found"

# First `version = "..."` inside the [package] table.
cargo_version="$(awk '
  /^[[:space:]]*\[/ { in_pkg = ($0 ~ /^[[:space:]]*\[package\][[:space:]]*(#.*)?$/) ; next }
  in_pkg && /^[[:space:]]*version[[:space:]]*=/ {
    line = $0
    sub(/^[^"]*"/, "", line)
    sub(/".*$/, "", line)
    print line
    exit
  }
' "$cargo_toml")"
[ -n "$cargo_version" ] || fail "could not read [package] version from Cargo.toml"

if [ "$version" != "$cargo_version" ]; then
  fail "tag version ($version) does not match Cargo.toml version ($cargo_version)"
fi

main_ref="${MAIN_REF:-origin/main}"
commit="${COMMIT:-HEAD}"

git rev-parse --verify --quiet "${main_ref}^{commit}" >/dev/null \
  || fail "main ref '${main_ref}' not found (was the checkout shallow? use fetch-depth: 0)"
git rev-parse --verify --quiet "${commit}^{commit}" >/dev/null \
  || fail "commit '${commit}' not found"

if ! git merge-base --is-ancestor "$commit" "$main_ref"; then
  fail "tagged commit is not an ancestor of ${main_ref}; releases must come from main"
fi

printf 'ok: %s matches Cargo.toml and is on %s\n' "$tag" "$main_ref"
