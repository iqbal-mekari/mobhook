#!/usr/bin/env bash
# YAML parse + structural checks for workflows and dependabot.yml.
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

echo "workflows: structure"
if command -v ruby >/dev/null 2>&1 && ruby -ryaml -e 'exit 0' >/dev/null 2>&1; then
  if ruby "$(dirname "$0")/workflow_checks.rb" "$REPO_ROOT"; then
    pass "ruby structural checks"
  else
    fail "ruby structural checks"
  fi
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  for f in "$WORKFLOWS_DIR"/*.yml "$REPO_ROOT/.github/dependabot.yml"; do
    expect_ok "python yaml parses $(basename "$f")" python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$f"
  done
  fail "structural checks need ruby" "only YAML parsing ran"
elif [ "${ALLOW_NO_YAML:-0}" = "1" ]; then
  echo "  SKIP no YAML parser (ruby or python3+yaml) available; ALLOW_NO_YAML=1"
else
  fail "no YAML parser available" "install ruby or python3+pyyaml, or set ALLOW_NO_YAML=1"
fi

echo "workflows: grep-style checks"
# Independent of the YAML parser.
if grep -nE '^\s*-?\s*uses:\s*\S+@(v[0-9]|stable|main|master)' "$WORKFLOWS_DIR"/*.yml >/dev/null; then
  fail "no tag-pinned actions (grep)"
else
  pass "no tag-pinned actions (grep)"
fi
if grep -nE '^\s+run:.*\$\{\{' "$WORKFLOWS_DIR"/*.yml >/dev/null; then
  fail "no inline-run interpolation (grep)"
else
  pass "no inline-run interpolation (grep)"
fi
if grep -nE 'github\.ref_name' "$WORKFLOWS_DIR/release.yml" | grep -vE '^\s*[0-9]+:\s*RELEASE_TAG: \$\{\{ github\.ref_name \}\}\s*$' | grep -v 'on:' >/dev/null; then
  fail "github.ref_name only assigned to RELEASE_TAG env"
else
  pass "github.ref_name only assigned to RELEASE_TAG env"
fi

echo "workflows: scripts referenced exist and parse"
for s in validate-release-tag.sh render-formula.sh git-askpass.sh; do
  [ -f "$SCRIPTS_DIR/$s" ] && pass "exists: $s" || fail "missing: $s"
done
expect_ok "bash -n validate-release-tag.sh" bash -n "$SCRIPTS_DIR/validate-release-tag.sh"
expect_ok "bash -n render-formula.sh" bash -n "$SCRIPTS_DIR/render-formula.sh"
for s in validate-release-tag.sh render-formula.sh git-askpass.sh; do
  [ -x "$SCRIPTS_DIR/$s" ] && pass "executable: $s" || fail "not executable: $s"
done

echo "repo hygiene"
for p in '.DS_Store' '.env*' '*.pem' '*.key' '*.p12' '*.jks' 'google-services.json' 'GoogleService-Info.plist' '.hook-reports/' '/target'; do
  if grep -qxF "$p" "$REPO_ROOT/.gitignore"; then pass ".gitignore has $p"; else fail ".gitignore missing $p"; fi
done
grep -q 'Private Vulnerability Reporting' "$REPO_ROOT/SECURITY.md" && pass "SECURITY.md mentions private reporting" || fail "SECURITY.md private reporting"
grep -q 'TO BE FILLED IN' "$REPO_ROOT/SECURITY.md" && pass "SECURITY.md contact is a placeholder" || fail "SECURITY.md placeholder"
grep -q '^## \[Unreleased\]' "$REPO_ROOT/CHANGELOG.md" && pass "CHANGELOG has Unreleased" || fail "CHANGELOG Unreleased"
for v in 0.3.0 0.2.0 0.1.1 0.1.0; do
  grep -q "^## \[$v\]" "$REPO_ROOT/CHANGELOG.md" && pass "CHANGELOG has $v" || fail "CHANGELOG missing $v"
done

finish "workflows"
