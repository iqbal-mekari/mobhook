#!/usr/bin/env bash
# Tests for .github/scripts/render-formula.sh and git-askpass.sh
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SCRIPT="$SCRIPTS_DIR/render-formula.sh"
ASKPASS="$SCRIPTS_DIR/git-askpass.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/render-formula.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

H1=$(printf 'a%.0s' $(seq 1 64))
H2=$(printf 'b%.0s' $(seq 1 64))
H3=$(printf '1%.0s' $(seq 1 64))
H4=$(printf 'C%.0s' $(seq 1 64))
render() { bash "$SCRIPT" "$@"; }

echo "render-formula.sh: valid input"
out="$(render 1.2.3 "$H1" "$H2" "$H3" "$H4")"
assert_contains "version line" "$out" 'version "1.2.3"'
BASE="https://github.com/iqbal-mekari/mobhook/releases/download/v1.2.3"
assert_contains "url arm mac"    "$out" "url \"$BASE/mobhook-aarch64-apple-darwin.tar.gz\""
assert_contains "url x64 mac"    "$out" "url \"$BASE/mobhook-x86_64-apple-darwin.tar.gz\""
assert_contains "url arm linux"  "$out" "url \"$BASE/mobhook-aarch64-unknown-linux-musl.tar.gz\""
assert_contains "url x64 linux"  "$out" "url \"$BASE/mobhook-x86_64-unknown-linux-musl.tar.gz\""
assert_contains "sha arm mac"    "$out" "sha256 \"$H1\""
assert_contains "sha x64 mac"    "$out" "sha256 \"$H2\""
assert_contains "sha arm linux"  "$out" "sha256 \"$H3\""
assert_contains "sha x64 linux"  "$out" "sha256 \"$H4\""
assert_contains "strong formula test" "$out" 'assert_match version.to_s, shell_output("#{bin}/mobhook --version")'
assert_contains "ruby interpolation preserved" "$out" '#{bin}'
assert_not_contains "no unexpanded \${" "$out" '${'
assert_not_contains "no leftover placeholder" "$out" '@VERSION@'
assert_not_contains "no leftover sha placeholder" "$out" '@ARM_MAC@'
# mac block must pair with the right checksum (order check)
mac_line="$(printf '%s\n' "$out" | grep -n 'aarch64-apple-darwin' | head -1 | cut -d: -f1)"
sha_after="$(printf '%s\n' "$out" | sed -n "$((mac_line + 1))p")"
assert_contains "arm mac url followed by arm mac sha" "$sha_after" "$H1"

out2="$(render 1.2.3-rc.1 "$H1" "$H2" "$H3" "$H4")"
assert_contains "prerelease version accepted" "$out2" 'version "1.2.3-rc.1"'
assert_contains "prerelease url" "$out2" '/download/v1.2.3-rc.1/mobhook-'

echo "render-formula.sh: output file"
OUT="$WORK/mobhook.rb"
render 1.2.3 "$H1" "$H2" "$H3" "$H4" "$OUT" >/dev/null
[ "$(cat "$OUT")" = "$out" ] && pass "file output equals stdout" || fail "file output differs"
if command -v ruby >/dev/null 2>&1; then
  expect_ok "rendered formula is valid Ruby" ruby -c "$OUT"
fi

echo "render-formula.sh: rejection"
bad_version() {
  local f="$WORK/bad.rb"
  rm -f "$f"
  if render "$1" "$H1" "$H2" "$H3" "$H4" "$f" >"$WORK/stdout" 2>"$WORK/stderr"; then
    fail "reject version '$1'" "accepted"
    return
  fi
  if [ -e "$f" ] || [ -s "$WORK/stdout" ]; then
    fail "reject version '$1'" "output produced despite failure"
  else
    pass "reject version '$1' (no output)"
  fi
}
SENTINEL="$WORK/pwned"
for v in "" v1.2.3 1.2 1.2.3.4 1.2.3+meta 01.2.3 1.2.3- 1.2.3-01 foo \
         '1.0.0"; system("id"); "' '1.0.0"' "1.0.0'" '1.0.0$(id)' '1.0.0`id`' '1.0.0#{`id`}' \
         '1.0.0${IFS}' "1.0.0; touch $SENTINEL" $'1.0.0\nsha256 "x"' $'1.0.0\n' '1.0.0 ' '1.0.0&' '1.0.0\\'; do
  bad_version "$v"
done
[ ! -e "$SENTINEL" ] && pass "hostile VERSION never executed" || fail "sentinel created"

bad_sha() {
  # bad_sha POSITION VALUE
  local args=("$H1" "$H2" "$H3" "$H4")
  args[$1]="$2"
  expect_fail "reject checksum #$1 '$2'" render 1.2.3 "${args[@]}"
}
SHORT="${H1%?}"
LONG="${H1}a"
for pos in 0 1 2 3; do
  bad_sha "$pos" ""
  bad_sha "$pos" "$SHORT"
  bad_sha "$pos" "$LONG"
  bad_sha "$pos" "$(printf 'g%.0s' $(seq 1 64))"
  bad_sha "$pos" "${H1%??}\"; "
  bad_sha "$pos" "${H1%?????}\$(id)"
  bad_sha "$pos" "$H1"$'\n'
done
expect_fail "too few arguments" render 1.2.3 "$H1" "$H2" "$H3"
expect_fail "too many arguments" render 1.2.3 "$H1" "$H2" "$H3" "$H4" "$WORK/o" extra
expect_fail "no arguments" render

echo "render-formula.sh: hostile text cannot reach output"
# A version that passes validation is the only thing substituted; confirm the
# output contains no characters outside the validated alphabet on the version line.
vline="$(printf '%s\n' "$out2" | grep '^  version ')"
case "$vline" in
  *[!A-Za-z0-9.\"\ -]*) fail "version line has unexpected characters" "$vline" ;;
  *) pass "version line limited to validated alphabet" ;;
esac

echo "git-askpass.sh"
expect_ok "sh syntax" sh -n "$ASKPASS"
u="$(TAP_TOKEN=dummy-not-a-secret sh "$ASKPASS" "Username for 'https://github.com': ")"
[ "$u" = "x-access-token" ] && pass "username prompt" || fail "username prompt" "$u"
p="$(TAP_TOKEN=dummy-not-a-secret sh "$ASKPASS" "Password for 'https://x-access-token@github.com': ")"
[ "$p" = "dummy-not-a-secret" ] && pass "password prompt reads env" || fail "password prompt"
expect_fail "password prompt without TAP_TOKEN" env -u TAP_TOKEN sh "$ASKPASS" "Password for 'x': "
expect_fail "unknown prompt" env TAP_TOKEN=x sh "$ASKPASS" "Something else"
if grep -nE '[0-9a-f]{40}|ghp_|github_pat_' "$ASKPASS" >/dev/null; then
  fail "askpass contains no embedded secret" "token-like string found"
else
  pass "askpass contains no embedded secret"
fi

finish "render-formula"
