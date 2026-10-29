#!/usr/bin/env bash
# Runs every release-script test. Exit 0 only if all pass.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
status=0
for t in test_validate_release_tag.sh test_render_formula.sh test_workflows.sh; do
  echo "=== $t"
  if ! bash "$DIR/$t"; then
    status=1
  fi
done
if [ "$status" -eq 0 ]; then
  echo "RELEASE TESTS: ALL PASSED"
else
  echo "RELEASE TESTS: FAILURES" >&2
fi
exit "$status"
