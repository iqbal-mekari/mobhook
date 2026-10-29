#!/usr/bin/env bash
# Tests for .github/scripts/validate-release-tag.sh
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
git_isolate

SCRIPT="$SCRIPTS_DIR/validate-release-tag.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/validate-tag.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fmt() { RELEASE_TAG="$1" bash "$SCRIPT" --format-only; }

echo "validate-release-tag.sh: format"
for t in v0.0.0 v1.2.3 v10.20.30 v1.2.3-rc.1 v1.2.3-alpha v1.2.3-0.3.7 v1.2.3-x-y-z.1; do
  expect_ok "accept $t" fmt "$t"
done
for t in 1.2.3 vfoo v1.2 v1 v1.2.3.4 'v1.2.3;' v1.2.3+build v1.2.3-rc.1+b V1.2.3 v01.2.3 v1.02.3 v1.2.03 \
         v1.2.3- v1.2.3-01 v1.2.3-rc..1 v1.2.3foo ' v1.2.3' 'v1.2.3 ' v-1.2.3 v1.2.3/evil; do
  expect_fail "reject '$t'" fmt "$t"
done

echo "validate-release-tag.sh: injection and control characters"
expect_fail "reject empty" fmt ""
expect_fail "reject unset" env -u RELEASE_TAG bash "$SCRIPT" --format-only
SENTINEL="$WORK/pwned"
for t in \
  "v1.0.0\"; touch $SENTINEL" \
  "v1.0.0; touch $SENTINEL" \
  'v1.0.0$(id)' \
  'v1.0.0`id`' \
  'v1.0.0${IFS}x' \
  $'v1.0.0\nfoo' \
  $'v1.0.0\n' \
  $'v1.0.0\r' \
  $'v1.2.3\n1.2.3' \
  "v1.0.0' || true"; do
  expect_fail "reject hostile tag" fmt "$t"
done
out="$(RELEASE_TAG='v1.0.0$(id)' bash "$SCRIPT" --format-only 2>&1 || true)"
assert_not_contains "no command substitution output" "$out" "uid="
assert_not_contains "raw tag is not echoed" "$out" 'v1.0.0$(id)'
[ ! -e "$SENTINEL" ] && pass "no side effects from hostile tags" || fail "sentinel created"
expect_fail "reject unknown argument" env RELEASE_TAG=v1.2.3 bash "$SCRIPT" --nope

echo "validate-release-tag.sh: Cargo.toml version and main ancestry"
mkrepo() {
  # mkrepo DIR CARGO_VERSION
  local d="$1" v="$2"
  mkdir -p "$d"
  (
    cd "$d" || exit 1
    git init -q
    git checkout -q -b main
    cat > Cargo.toml <<CARGO
[package]
name = "demo"
version = "$v"
edition = "2021"

[dependencies]
foo = { version = "9.9.9" }

[dependencies.bar]
version = "7.7.7"
CARGO
    git add Cargo.toml
    git commit -q -m "init"
  )
}
full() {
  # full DIR TAG [extra env...]   (runs in DIR)
  local d="$1" t="$2"
  shift 2
  (cd "$d" && env RELEASE_TAG="$t" MAIN_REF=main "$@" bash "$SCRIPT")
}

R1="$WORK/r1"
mkrepo "$R1" 1.0.0
expect_ok   "tag == Cargo version, on main" full "$R1" v1.0.0
expect_fail "tag newer than Cargo version" full "$R1" v1.0.1
expect_fail "tag older than Cargo version" full "$R1" v0.9.9
expect_fail "prerelease tag vs plain Cargo version" full "$R1" v1.0.0-rc.1
expect_fail "dependency version is not used" full "$R1" v9.9.9
expect_fail "dependency table version is not used" full "$R1" v7.7.7
expect_fail "bad format fails in full mode" full "$R1" 1.0.0
expect_fail "missing main ref" full "$R1" v1.0.0 MAIN_REF=does-not-exist
expect_fail "missing Cargo.toml" full "$R1" v1.0.0 CARGO_TOML="$WORK/nope.toml"
expect_ok   "explicit CARGO_TOML path" full "$R1" v1.0.0 CARGO_TOML="$R1/Cargo.toml"
msg="$(full "$R1" v1.0.1 2>&1 || true)"
assert_contains "mismatch message names both versions" "$msg" "1.0.1"
assert_contains "mismatch message names Cargo version" "$msg" "1.0.0"

R2="$WORK/r2"
mkrepo "$R2" 1.0.0
(cd "$R2" && git checkout -q -b side && echo x > f && git add f && git commit -q -m side)
expect_fail "HEAD on a side branch (not in main)" full "$R2" v1.0.0
msg="$(full "$R2" v1.0.0 2>&1 || true)"
assert_contains "ancestry failure is explained" "$msg" "not an ancestor"
expect_ok   "side-branch commit passes once it is on main" \
  bash -c "cd '$R2' && git checkout -q main && git merge -q --ff-only side && RELEASE_TAG=v1.0.0 MAIN_REF=main bash '$SCRIPT'"
expect_ok   "COMMIT override to an ancestor of main" \
  bash -c "cd '$R2' && RELEASE_TAG=v1.0.0 MAIN_REF=main COMMIT=HEAD~1 bash '$SCRIPT'"

R3="$WORK/r3"
mkrepo "$R3" 2.0.0-rc.1
expect_ok "prerelease tag == prerelease Cargo version" full "$R3" v2.0.0-rc.1
cat > "$R3/Cargo.toml" <<'CARGO'
[dependencies]
foo = { version = "2.0.0" }
CARGO
expect_fail "no [package] version" full "$R3" v2.0.0

finish "validate-release-tag"
