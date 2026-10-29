#!/bin/bash
# =============================================================================
# Preset script tests (plain bash, no bats) — presets/security/**
# =============================================================================
# Covers the security hardening fixes S1-S8 for:
#   presets/security/script.sh
#   presets/security/ci-security-scan.sh
#   presets/security/gitleaks.toml
#   presets/security/.mobsf
#
# Safety rules for this suite:
#   - Scanners are STUBS (gitleaks, mobsfscan, semgrep, pipx, brew) placed first
#     on PATH. Nothing is installed, nothing touches the network.
#   - Everything is written inside one private mktemp -d directory (removed on
#     exit). TMPDIR is redirected there for every script under test.
#   - Only obviously fake dummy secrets are used (FAKE_TEST_SECRET_0123, and
#     fake tokens assembled at runtime so this file itself is not a leak).
#   - Tests that need the real gitleaks binary SKIP (with a message) if absent.
#
# Usage: bash tests/shell/presets/run_tests.sh   (exit 0 = all passed)
# =============================================================================

set -u

# Hooks export GIT_* variables; they must not leak into the throwaway repos
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
PRESET_DIR="$REPO_ROOT/presets/security"
SCRIPT_SH="$PRESET_DIR/script.sh"
CI_SH="$PRESET_DIR/ci-security-scan.sh"
GITLEAKS_TOML="$PRESET_DIR/gitleaks.toml"
MOBSF_CFG="$PRESET_DIR/.mobsf"

# Prefer the macOS system bash (3.2) so bash 3.2 compatibility is exercised
if [ -x /bin/bash ]; then BASH_BIN=/bin/bash; else BASH_BIN="$(command -v bash)"; fi

PASS=0
FAIL=0
SKIP=0

ok()   { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL  $1${2:+ -- $2}"; }
skip() { SKIP=$((SKIP + 1)); echo "  SKIP  $1 -- $2"; }
section() { echo ""; echo "== $1"; }

assert_eq() {  # name expected actual
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}
assert_ne() {  # name unexpected actual
    if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "did not expect '$3'"; fi
}
assert_contains() {  # name file needle
    if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1" "'$3' not found in $(basename "$2")"; fi
}
assert_not_contains() {  # name file needle
    if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1" "'$3' unexpectedly present in $(basename "$2")"; else ok "$1"; fi
}

file_mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

# ─── Sandbox ────────────────────────────────────────────────────────────────

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to run these tests (real jq is used, not a stub)"
    exit 1
fi

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mobhook-preset-tests.XXXXXX")" || exit 1
cleanup_suite() { rm -rf "$TEST_ROOT"; }
trap cleanup_suite EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Fake dummy values (never real secrets). The token is assembled at runtime so
# no literal token-shaped string exists in this file.
FAKE_SECRET="FAKE_TEST_SECRET_0123"
FAKE_BODY="aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bD1fH3jL5"      # 36 chars
FAKE_GH_TOKEN="ghp""_${FAKE_BODY}"

# Names the ORIGINAL scripts wrote to fixed /tmp paths
OLD_TMP_NAMES="/tmp/gitleaks-stdout.txt /tmp/mobsfscan-warnings.txt"
OLD_TMP_PRESENT=""
for f in $OLD_TMP_NAMES; do [ -e "$f" ] && OLD_TMP_PRESENT="$OLD_TMP_PRESENT $f"; done

# ─── Stub tools ─────────────────────────────────────────────────────────────

make_stubs() {  # bin_dir
    local bin="$1"
    mkdir -p "$bin"

    cat > "$bin/gitleaks" <<'STUB'
#!/bin/bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
report=""; prev=""
for a in "$@"; do
    if [ "$prev" = "--report-path" ]; then report="$a"; fi
    prev="$a"
done
echo "stub-gitleaks: scanning"
if [ -n "${STUB_GL_PIDFILE:-}" ]; then
    echo $$ > "$STUB_GL_PIDFILE"
    exec sleep 60
fi
if [ -n "$report" ]; then
    if [ -n "${STUB_GL_REPORT_SRC:-}" ]; then
        cp "$STUB_GL_REPORT_SRC" "$report"
    elif [ "${STUB_GL_EMPTY:-0}" = 1 ]; then
        : > "$report"
    fi
fi
if [ "${STUB_GL_EXIT:-0}" -ne 0 ]; then
    echo "stub-gitleaks: leaks found (values redacted)"
fi
exit "${STUB_GL_EXIT:-0}"
STUB

    cat > "$bin/mobsfscan" <<'STUB'
#!/bin/bash
case "${1:-}" in
    --version|-v) echo "stub-mobsfscan 0.0"; exit 0 ;;
esac
if [ -n "${STUB_MS_JSON_SRC:-}" ]; then
    cat "$STUB_MS_JSON_SRC"
elif [ "${STUB_MS_EMPTY:-0}" != 1 ]; then
    echo '{"results":{}}'
fi
exit "${STUB_MS_EXIT:-0}"
STUB

    cat > "$bin/semgrep" <<'STUB'
#!/bin/bash
exit 0
STUB

    cat > "$bin/pipx" <<'STUB'
#!/bin/bash
echo "pipx $*" >> "${STUB_LOG:-/dev/null}"
exit 0
STUB

    # brew must never really run; log the call and fail
    cat > "$bin/brew" <<'STUB'
#!/bin/bash
echo "brew $*" >> "${STUB_LOG:-/dev/null}"
exit 1
STUB
    chmod +x "$bin"/*
}

# new_case <name>: sets CASE_DIR BIN PROJ CASE_TMP STUB_LOG OUT
new_case() {
    CASE_DIR="$TEST_ROOT/$1"
    BIN="$CASE_DIR/bin"
    PROJ="$CASE_DIR/proj"
    CASE_TMP="$CASE_DIR/tmp"
    STUB_LOG="$CASE_DIR/stub.log"
    OUT="$CASE_DIR/out.txt"
    mkdir -p "$PROJ" "$CASE_TMP"
    : > "$STUB_LOG"
    make_stubs "$BIN"
    git -C "$PROJ" init -q 2>/dev/null
    echo "print('hello')" > "$PROJ/main.dart"
}

# run_script <script> [VAR=value ...]  — runs in $PROJ, output in $OUT, status in $RC
run_script() {
    local script="$1"; shift
    ( cd "$PROJ" && env PATH="$BIN:/usr/bin:/bin" TMPDIR="$CASE_TMP" STUB_LOG="$STUB_LOG" \
        ${1+"$@"} "$BASH_BIN" "$script" ) > "$OUT" 2>&1 < /dev/null
    RC=$?
}

# make_gl_report <file> <count> [file_field]  — gitleaks-shaped JSON with the fake secret
make_gl_report() {
    jq -n --argjson n "$2" --arg f "${3:-src/app.dart}" --arg s "$FAKE_SECRET" \
        '[range($n) | {RuleID:"github-pat", File:$f, StartLine:(. + 1), Match:("token = " + $s), Secret:$s}]' > "$1"
}

# make_ms_report <file> [file_path]  — mobsfscan-shaped JSON with the fake secret in match_string
make_ms_report() {
    jq -n --arg p "${2:-/p/Login.kt}" --arg s "$FAKE_SECRET" \
        '{results:{android_hardcoded:{metadata:{severity:"ERROR",cwe:"CWE-798",description:"d"},files:[{file_path:$p,match_lines:[3],match_string:("val k = " + $s)}]}}}' > "$1"
}

old_tmp_names_untouched() {  # name
    local f leaked=""
    for f in $OLD_TMP_NAMES; do
        case " $OLD_TMP_PRESENT " in
            *" $f "*) ;;                       # existed before us: not our business
            *) [ -e "$f" ] && leaked="$leaked $f" ;;
        esac
    done
    if [ -z "$leaked" ]; then ok "$1"; else bad "$1" "fixed /tmp path created:$leaked"; fi
}

no_leftover_workdirs() {  # name
    local left
    left="$(ls -d "$CASE_TMP"/mobhook-security.* 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "$1" "0" "$left"
}

# ─── 0. Static checks ──────────────────────────────────────────────────────

section "Static: syntax, bash 3.2 compatibility, banned constructs (S2, S3, S6)"

for f in "$SCRIPT_SH" "$CI_SH" "${BASH_SOURCE[0]}"; do
    if "$BASH_BIN" -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done

for f in "$SCRIPT_SH" "$CI_SH"; do
    n="$(basename "$f")"
    code="$(grep -v '^[[:space:]]*#' "$f")"
    if printf '%s\n' "$code" | grep -Eq '(^|[^A-Za-z0-9_])eval[[:space:]]'; then bad "S6 no eval in $n"; else ok "S6 no eval in $n"; fi
    if printf '%s\n' "$code" | grep -Eq '/tmp/(gitleaks|mobsfscan)'; then bad "S3 no fixed /tmp names in $n"; else ok "S3 no fixed /tmp names in $n"; fi
    if printf '%s\n' "$code" | grep -Eq '\(\([[:space:]]*[A-Za-z_]+\+\+[[:space:]]*\)\)'; then bad "S2 no ((x++)) in $n"; else ok "S2 no ((x++)) in $n"; fi
    if printf '%s\n' "$code" | grep -Eq 'mapfile|readarray|declare -A|typeset -A|\$\{[A-Za-z_]+(,,|\^\^)\}'; then bad "bash 3.2: no bash4-only syntax in $n"; else ok "bash 3.2: no bash4-only syntax in $n"; fi
    if printf '%s\n' "$code" | grep -Eq '\|[[:space:]]*tee[[:space:]]'; then bad "S1 no pipe to tee in $n"; else ok "S1 no pipe to tee in $n"; fi
    # every gitleaks invocation must carry --redact
    if [ "$(printf '%s\n' "$code" | grep -c -- '--redact')" -ge 1 ]; then ok "S4 --redact present in $n"; else bad "S4 --redact present in $n"; fi
done

if grep -q '^set -uo pipefail' "$SCRIPT_SH"; then ok "S2 script.sh has top-level set -uo pipefail"; else bad "S2 script.sh has top-level set -uo pipefail"; fi
if grep -q '^umask 077' "$SCRIPT_SH" && grep -q '^umask 077' "$CI_SH"; then ok "S4 umask 077 in both scripts"; else bad "S4 umask 077 in both scripts"; fi
if grep -q '^FAIL_ON_FINDINGS\|FAIL_ON_FINDINGS=1' "$CI_SH"; then ok "S5 FAIL_ON_FINDINGS documented in ci header"; else bad "S5 FAIL_ON_FINDINGS documented in ci header"; fi
if grep -q 'escape_md' "$SCRIPT_SH"; then bad "S8 dead escape_md removed"; else ok "S8 dead escape_md removed"; fi

section "Unit: pin_spec (S6) — no injection through version pins"
for f in "$SCRIPT_SH" "$CI_SH"; do
    n="$(basename "$f")"
    sed -n '/^pin_spec() {/,/^}/p' "$f" > "$TEST_ROOT/pin_spec_$n.sh"
    # shellcheck disable=SC1090
    ( . "$TEST_ROOT/pin_spec_$n.sh"
      [ "$(pin_spec mobsfscan "")" = "mobsfscan" ] ) && ok "pin_spec unpinned ($n)" || bad "pin_spec unpinned ($n)"
    ( . "$TEST_ROOT/pin_spec_$n.sh"
      [ "$(pin_spec mobsfscan "1.2.3")" = "mobsfscan==1.2.3" ] ) && ok "pin_spec pinned ($n)" || bad "pin_spec pinned ($n)"
    ( . "$TEST_ROOT/pin_spec_$n.sh"
      pin_spec mobsfscan '1;touch PWNED' >/dev/null 2>&1 ) && bad "pin_spec rejects shell metachars ($n)" || ok "pin_spec rejects shell metachars ($n)"
done

# ─── 1. script.sh — gate behaviour (S1, S2) ────────────────────────────────

section "S1/S2 script.sh: secret gate fails closed"

# (1) gitleaks exits 1 with a finding => non-zero + failure recorded
new_case s1_findings
make_gl_report "$CASE_DIR/gl.json" 1
run_script "$SCRIPT_SH" STUB_GL_EXIT=1 STUB_GL_REPORT_SRC="$CASE_DIR/gl.json"
assert_eq "S1 gitleaks exit 1 + finding => script exits 1" "1" "$RC"
assert_contains "S1 console reports the secret detection" "$OUT" "1 secret(s) detected"
MD="$PROJ/.hook-reports/security-scan-report.md"
assert_contains "S2 report still written after first failure" "$MD" "1 tool(s) failed"
assert_contains "S1 markdown status is Fail" "$MD" "❌ Fail"

# (2) clean => exit 0
new_case s1_clean
make_gl_report "$CASE_DIR/gl.json" 0
run_script "$SCRIPT_SH" STUB_GL_EXIT=0 STUB_GL_REPORT_SRC="$CASE_DIR/gl.json"
assert_eq "S1 gitleaks exit 0 + no findings => exit 0" "0" "$RC"
assert_contains "S1 clean run says no secrets" "$OUT" "No secrets found"
assert_contains "S2 clean report says all passed" "$PROJ/.hook-reports/security-scan-report.md" "All checks passed"

# (3) gitleaks fails with empty / missing / garbage report => failure
new_case s1_empty_report
run_script "$SCRIPT_SH" STUB_GL_EXIT=2 STUB_GL_EMPTY=1
assert_eq "S1 exit 2 + empty report => exit 1" "1" "$RC"
assert_contains "S1 empty report is named as scan failure" "$OUT" "scan failed (exit code 2)"
assert_contains "S1 markdown explains the failure (not 'no secrets')" "$PROJ/.hook-reports/security-scan-report.md" "scan failed or produced no usable report"
assert_not_contains "S1 markdown does not claim clean on failure" "$PROJ/.hook-reports/security-scan-report.md" "No secrets or credentials detected"

new_case s1_untouched_report
run_script "$SCRIPT_SH" STUB_GL_EXIT=3
assert_eq "S1 exit 3 + report never written => exit 1" "1" "$RC"

new_case s1_garbage_report
echo "this is not json" > "$CASE_DIR/garbage.json"
run_script "$SCRIPT_SH" STUB_GL_EXIT=0 STUB_GL_REPORT_SRC="$CASE_DIR/garbage.json"
assert_eq "S1 exit 0 + unparseable report => exit 1 (fail closed)" "1" "$RC"
assert_contains "S1 unparseable report is named" "$OUT" "report missing or unparseable"

new_case s1_warning_only
make_gl_report "$CASE_DIR/gl.json" 1
run_script "$SCRIPT_SH" STUB_GL_EXIT=0 STUB_GL_REPORT_SRC="$CASE_DIR/gl.json"
assert_eq "existing behaviour kept: exit 0 + findings => warning, exit 0" "0" "$RC"
assert_contains "warning status shown" "$OUT" "1 warning(s)"

section "S2 script.sh: mobsfscan + combined failure accounting"

new_case ms_findings
make_ms_report "$CASE_DIR/ms.json"
run_script "$SCRIPT_SH" STUB_MS_EXIT=1 STUB_MS_JSON_SRC="$CASE_DIR/ms.json"
assert_eq "mobsfscan exit 1 + finding => exit 1" "1" "$RC"
assert_contains "mobsfscan failure counted" "$PROJ/.hook-reports/security-scan-report.md" "1 tool(s) failed"

new_case ms_crash
run_script "$SCRIPT_SH" STUB_MS_EXIT=2 STUB_MS_EMPTY=1
assert_eq "mobsfscan exit 2 + empty output => exit 1" "1" "$RC"
assert_contains "mobsfscan crash named" "$OUT" "scan failed (exit code 2)"

new_case both_fail
make_gl_report "$CASE_DIR/gl.json" 1
make_ms_report "$CASE_DIR/ms.json"
run_script "$SCRIPT_SH" STUB_GL_EXIT=1 STUB_GL_REPORT_SRC="$CASE_DIR/gl.json" STUB_MS_EXIT=1 STUB_MS_JSON_SRC="$CASE_DIR/ms.json"
assert_eq "both tools failing => exit 1" "1" "$RC"
assert_contains "counter reaches 2 (no errexit abort at 0->1)" "$PROJ/.hook-reports/security-scan-report.md" "2 tool(s) failed"

# ─── 2. Temp files (S3) ────────────────────────────────────────────────────

section "S3 script.sh: private temp dir, cleaned on exit and on signals"

new_case tmp_normal
run_script "$SCRIPT_SH"
assert_eq "normal run exits 0" "0" "$RC"
no_leftover_workdirs "S3 no temp dir left after normal exit"
old_tmp_names_untouched "S3 old fixed /tmp names not created (normal run)"

new_case tmp_fail
make_gl_report "$CASE_DIR/gl.json" 1
run_script "$SCRIPT_SH" STUB_GL_EXIT=1 STUB_GL_REPORT_SRC="$CASE_DIR/gl.json"
no_leftover_workdirs "S3 no temp dir left after failing run"

# signal_case <INT|TERM> <expected rc>
signal_case() {
    local sig="$1" want="$2" i pid glpid wd mode
    new_case "tmp_sig_$sig"
    ( cd "$PROJ" && exec env PATH="$BIN:/usr/bin:/bin" TMPDIR="$CASE_TMP" STUB_LOG="$STUB_LOG" \
        STUB_GL_PIDFILE="$CASE_DIR/gl.pid" \
        perl -e '$SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; exec @ARGV' "$BASH_BIN" "$SCRIPT_SH" ) \
        > "$OUT" 2>&1 < /dev/null &
    pid=$!
    for i in $(seq 1 100); do
        [ -s "$CASE_DIR/gl.pid" ] && break
        sleep 0.1
    done
    if [ ! -s "$CASE_DIR/gl.pid" ]; then
        bad "SIG$sig: script reached the (stub) gitleaks step"; kill -9 "$pid" 2>/dev/null; return
    fi
    glpid="$(cat "$CASE_DIR/gl.pid")"
    wd="$(ls -d "$CASE_TMP"/mobhook-security.* 2>/dev/null | head -1)"
    if [ -n "$wd" ] && [ -d "$wd" ]; then ok "SIG$sig: temp dir exists mid-run"; else bad "SIG$sig: temp dir exists mid-run"; fi
    mode="$(file_mode "$wd")"
    assert_eq "S3 temp dir is private (0700) mid-run" "700" "$mode"
    # A terminal ^C hits the whole foreground group: signal the script and its child
    kill "-$sig" "$pid" 2>/dev/null
    kill "-$sig" "$glpid" 2>/dev/null
    for i in $(seq 1 100); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        bad "SIG$sig: script terminated"; kill -9 "$pid" 2>/dev/null; kill -9 "$glpid" 2>/dev/null
    else
        wait "$pid"; RC=$?
        assert_eq "SIG$sig: exit status" "$want" "$RC"
    fi
    no_leftover_workdirs "S3 temp dir removed after SIG$sig mid-run"
    old_tmp_names_untouched "S3 old fixed /tmp names not created (SIG$sig)"
}

signal_case TERM 143
if command -v perl >/dev/null 2>&1; then
    signal_case INT 130
else
    skip "SIGINT cleanup" "perl not available to un-ignore SIGINT for a background job"
fi

# ─── 3. No raw secrets, file modes (S4, S8) ────────────────────────────────

section "S4/S8 script.sh: no raw secret in console or markdown, modes 600, --redact passed"

new_case s4_secret
make_gl_report "$CASE_DIR/gl.json" 3
make_ms_report "$CASE_DIR/ms.json"
run_script "$SCRIPT_SH" STUB_GL_EXIT=1 STUB_GL_REPORT_SRC="$CASE_DIR/gl.json" STUB_MS_EXIT=1 STUB_MS_JSON_SRC="$CASE_DIR/ms.json"
MD="$PROJ/.hook-reports/security-scan-report.md"
assert_not_contains "S4 console has no raw secret" "$OUT" "$FAKE_SECRET"
assert_not_contains "S4 markdown has no raw secret" "$MD" "$FAKE_SECRET"
assert_contains "S4 markdown shows masked marker" "$MD" "[REDACTED]"
assert_contains "S4 markdown still lists rule id" "$MD" "github-pat"
assert_contains "S4 markdown still lists file" "$MD" "src/app.dart"
assert_contains "S4 gitleaks invoked with --redact" "$STUB_LOG" "--redact"
assert_eq "S4 gitleaks-report.json mode" "600" "$(file_mode "$PROJ/.hook-reports/gitleaks-report.json")"
assert_eq "S4 mobsfscan-report.json mode" "600" "$(file_mode "$PROJ/.hook-reports/mobsfscan-report.json")"
assert_eq "S4 markdown report mode" "600" "$(file_mode "$MD")"
assert_eq "S4 reports dir mode (umask 077)" "700" "$(file_mode "$PROJ/.hook-reports")"

section "S8 script.sh: markdown table injection is neutralised"

new_case s8_inject
printf '%s' "src/a|b\`c\`
INJECT.dart" > "$CASE_DIR/evilname.txt"
make_gl_report "$CASE_DIR/gl.json" 1 "$(cat "$CASE_DIR/evilname.txt")"
make_ms_report "$CASE_DIR/ms.json" '/p/we|ird`x`
NAME.kt'
run_script "$SCRIPT_SH" STUB_GL_EXIT=1 STUB_GL_REPORT_SRC="$CASE_DIR/gl.json" STUB_MS_EXIT=1 STUB_MS_JSON_SRC="$CASE_DIR/ms.json"
MD="$PROJ/.hook-reports/security-scan-report.md"
ROW="$(grep '^| 1 | github-pat' "$MD" | head -1)"
assert_eq "S8 gitleaks row has exactly 6 cell separators" "6" "$(printf '%s' "$ROW" | tr -cd '|' | wc -c | tr -d ' ')"
case "$ROW" in *'`'*) bad "S8 gitleaks row has no backticks" ;; *) ok "S8 gitleaks row has no backticks" ;; esac
if grep -q '^INJECT' "$MD"; then bad "S8 newline in File cannot start a new markdown line"; else ok "S8 newline in File cannot start a new markdown line"; fi
MROW="$(grep '^| | android_hardcoded' "$MD" | head -1)"
assert_eq "S8 mobsfscan row has exactly 6 cell separators" "6" "$(printf '%s' "$MROW" | tr -cd '|' | wc -c | tr -d ' ')"
if grep -q '^NAME' "$MD"; then bad "S8 newline in mobsf file cannot start a new line"; else ok "S8 newline in mobsf file cannot start a new line"; fi

# ─── 4. ci-security-scan.sh (S4, S5, S6, S3) ───────────────────────────────

section "S5/S4/S3 ci-security-scan.sh"

ci_env() { echo "SCAN_DIR=$PROJ PROJECT_NAME=fake-proj BRANCH_NAME=main COMMIT_SHA=abc1234"; }

new_case ci_default
make_gl_report "$CASE_DIR/gl.json" 7
make_ms_report "$CASE_DIR/ms.json"
# shellcheck disable=SC2046
run_script "$CI_SH" $(ci_env) STUB_GL_EXIT=1 STUB_GL_REPORT_SRC="$CASE_DIR/gl.json" STUB_MS_EXIT=1 STUB_MS_JSON_SRC="$CASE_DIR/ms.json"
SUM="$PROJ/.hook-reports/scan-summary.json"
assert_eq "S5 default (FAIL_ON_FINDINGS unset) exits 0 despite findings" "0" "$RC"
assert_eq "S5 scan-summary.json status still fail" "fail" "$(jq -r .status "$SUM")"
assert_eq "S5 scan-summary.json totalFailures" "2" "$(jq -r .totalFailures "$SUM")"
assert_not_contains "S4 ci console has no raw secret" "$OUT" "$FAKE_SECRET"
assert_not_contains "S4 scan-summary.json has no raw secret" "$SUM" "$FAKE_SECRET"
assert_contains "S4 ci console masks Match" "$OUT" "Match : [REDACTED]"
assert_contains "S4 ci gitleaks invoked with --redact" "$STUB_LOG" "--redact"
assert_eq "S4 ci gitleaks-report.json mode" "600" "$(file_mode "$PROJ/.hook-reports/gitleaks-report.json")"
assert_eq "S4 ci scan-summary.json mode" "600" "$(file_mode "$SUM")"
assert_eq "S4 ci reports dir mode" "700" "$(file_mode "$PROJ/.hook-reports")"
# S5 cosmetic fix: the "... and N more" suffix must be on a real new line, not a literal \n
if jq -r .gitleaks.summary "$SUM" | grep -q '^\.\.\. and 2 more$'; then ok "S5 summary uses a real newline before '... and N more'"; else bad "S5 summary uses a real newline before '... and N more'"; fi
case "$(jq -r .gitleaks.summary "$SUM")" in *'\n'*) bad "S5 no literal \\n in summary" ;; *) ok "S5 no literal \\n in summary" ;; esac
no_leftover_workdirs "S3 ci leaves no mobhook temp dirs"
old_tmp_names_untouched "S3 ci creates no fixed /tmp names"

new_case ci_fail_on
make_gl_report "$CASE_DIR/gl.json" 1
# shellcheck disable=SC2046
run_script "$CI_SH" $(ci_env) FAIL_ON_FINDINGS=1 STUB_GL_EXIT=1 STUB_GL_REPORT_SRC="$CASE_DIR/gl.json"
assert_eq "S5 FAIL_ON_FINDINGS=1 + findings => exit 1" "1" "$RC"
assert_eq "S5 summary still written with FAIL_ON_FINDINGS=1" "fail" "$(jq -r .status "$PROJ/.hook-reports/scan-summary.json")"

new_case ci_fail_on_clean
make_gl_report "$CASE_DIR/gl.json" 0
# shellcheck disable=SC2046
run_script "$CI_SH" $(ci_env) FAIL_ON_FINDINGS=1 STUB_GL_EXIT=0 STUB_GL_REPORT_SRC="$CASE_DIR/gl.json"
assert_eq "S5 FAIL_ON_FINDINGS=1 + clean => exit 0" "0" "$RC"
assert_eq "S5 clean summary status" "pass" "$(jq -r .status "$PROJ/.hook-reports/scan-summary.json")"

new_case ci_gl_crash
mkdir -p "$PROJ/.hook-reports"
echo "[]" > "$PROJ/.hook-reports/gitleaks-report.json"      # stale 'clean' report from an earlier run
# shellcheck disable=SC2046
run_script "$CI_SH" $(ci_env) FAIL_ON_FINDINGS=1 STUB_GL_EXIT=2
assert_eq "S1 ci: gitleaks crash + stale clean report => exit 1 with FAIL_ON_FINDINGS" "1" "$RC"
assert_contains "S1 ci: crash reported as failure" "$OUT" "gitleaks failed (exit code 2)"
assert_eq "S1 ci: summary marks failure" "fail" "$(jq -r .status "$PROJ/.hook-reports/scan-summary.json")"

section "S6 ci-security-scan.sh: installers get args, never a command string"

new_case ci_no_gitleaks
rm -f "$BIN/gitleaks"
# shellcheck disable=SC2046
run_script "$CI_SH" $(ci_env)
assert_eq "missing gitleaks + failed install => exit 1" "1" "$RC"
assert_contains "S6 brew received split args" "$STUB_LOG" "brew install gitleaks"
assert_contains "S6 FATAL message names the installer" "$OUT" "[FATAL] gitleaks installation failed"

new_case ci_bad_pin
# shellcheck disable=SC2046
run_script "$CI_SH" $(ci_env) MOBSFSCAN_VERSION='1;touch PWNED'
assert_ne "S6 invalid MOBSFSCAN_VERSION is rejected" "0" "$RC"
if [ -e "$PROJ/PWNED" ] || [ -e "$PROJ/../PWNED" ]; then bad "S6 pin value never executed"; else ok "S6 pin value never executed"; fi

# ─── 5. Real gitleaks: config validity and allowlist anchoring (S7) ────────

section "S7 gitleaks.toml (real gitleaks)"

REAL_GITLEAKS="$(command -v gitleaks 2>/dev/null || true)"
if [ -z "$REAL_GITLEAKS" ]; then
    skip "S7 gitleaks.toml load + allowlist + private-key rule + e2e" "gitleaks binary not found on PATH"
else
    GL_DIR="$(dirname "$REAL_GITLEAKS")"
    GL_ROOT="$TEST_ROOT/real"
    mkdir -p "$GL_ROOT/empty"

    "$REAL_GITLEAKS" detect --config "$GITLEAKS_TOML" --no-git --source "$GL_ROOT/empty" > "$GL_ROOT/load.out" 2>&1
    assert_eq "S7 gitleaks.toml loads (empty dir scan exits 0)" "0" "$?"
    assert_not_contains "S7 no config error in output" "$GL_ROOT/load.out" "failed to load config"

    if grep -q '^useDefault = true' "$GITLEAKS_TOML" && grep -q '^\[extend\]' "$GITLEAKS_TOML"; then ok "S7 [extend] useDefault = true present"; else bad "S7 [extend] useDefault = true present"; fi

    # Planted FAKE secrets in a project dir; scanned with --source . so allowlist
    # regexes see short relative paths (independent of where the sandbox lives).
    P="$GL_ROOT/proj"
    mkdir -p "$P/contest" "$P/test" "$P/build" "$P/lib" "$P/keys"
    LINE="API_TOKEN=$FAKE_GH_TOKEN"
    echo "$LINE" > "$P/.env"                # credential-bearing: must be flagged now
    echo "$LINE" > "$P/key.properties"      # credential-bearing: must be flagged now
    echo "$LINE" > "$P/contest/data.txt"    # 'contest/' must NOT be swallowed by 'test/'
    echo "$LINE" > "$P/test/data.txt"       # real test/ dir: ignored
    echo "$LINE" > "$P/build/data.txt"      # real build/ dir: ignored
    echo "$LINE" > "$P/.env.example"        # template: ignored
    echo "$LINE" > "$P/lib/secrets.txt"     # control: flagged
    # private-key headers assembled at runtime (not contiguous in this file)
    printf '%s\n' "-----BEGIN ""ENCRYPTED PRIVATE KEY-----" > "$P/keys/enc.txt"
    printf '%s\n' "-----BEGIN ""PGP PRIVATE KEY BLOCK-----" > "$P/keys/pgp.txt"
    printf '%s\n' "-----BEGIN ""OPENSSH PRIVATE KEY-----" > "$P/keys/ossh.txt"
    printf '%s\n' "-----BEGIN ""RSA PRIVATE KEY-----" > "$P/keys/rsa.txt"

    ( cd "$P" && "$REAL_GITLEAKS" detect --config "$GITLEAKS_TOML" --no-git --source . --redact \
        --report-path "$GL_ROOT/report.json" --report-format json > "$GL_ROOT/scan.out" 2>&1 )
    assert_eq "S7 planted fake secrets => gitleaks exit 1" "1" "$?"

    flagged() { jq -e --arg f "$1" '[.[] | select(.File == $f or .File == ("./" + $f))] | length > 0' "$GL_ROOT/report.json" >/dev/null 2>&1; }
    flagged_rule() { jq -e --arg f "$1" --arg r "$2" '[.[] | select((.File == $f or .File == ("./" + $f)) and .RuleID == $r)] | length > 0' "$GL_ROOT/report.json" >/dev/null 2>&1; }

    flagged ".env"               && ok "S7 tracked .env is flagged"                       || bad "S7 tracked .env is flagged"
    flagged "key.properties"     && ok "S7 key.properties is flagged"                     || bad "S7 key.properties is flagged"
    flagged "contest/data.txt"   && ok "S7 anchored allowlist: contest/ is NOT ignored"   || bad "S7 anchored allowlist: contest/ is NOT ignored"
    flagged "lib/secrets.txt"    && ok "S7 control file flagged"                          || bad "S7 control file flagged"
    flagged "test/data.txt"      && bad "S7 test/ dir still ignored"      || ok "S7 test/ dir still ignored"
    flagged "build/data.txt"     && bad "S7 build/ dir still ignored"     || ok "S7 build/ dir still ignored"
    flagged ".env.example"       && bad "S7 .env.example still ignored"   || ok "S7 .env.example still ignored"
    flagged_rule "keys/enc.txt"  private-key && ok "S7 ENCRYPTED PRIVATE KEY header matched"  || bad "S7 ENCRYPTED PRIVATE KEY header matched"
    flagged_rule "keys/pgp.txt"  private-key && ok "S7 PGP PRIVATE KEY BLOCK header matched"  || bad "S7 PGP PRIVATE KEY BLOCK header matched"
    flagged_rule "keys/ossh.txt" private-key && ok "S7 OPENSSH PRIVATE KEY header matched"    || bad "S7 OPENSSH PRIVATE KEY header matched"
    flagged_rule "keys/rsa.txt"  private-key && ok "S7 RSA PRIVATE KEY header still matched"  || bad "S7 RSA PRIVATE KEY header still matched"

    assert_not_contains "S4 real --redact: report has no raw planted token" "$GL_ROOT/report.json" "$FAKE_BODY"
    assert_not_contains "S4 real --redact: stdout has no raw planted token" "$GL_ROOT/scan.out" "$FAKE_BODY"
    if jq -e '[.[] | has("Severity")] | any | not' "$GL_ROOT/report.json" >/dev/null 2>&1; then ok "S7 gitleaks emits no Severity field (scripts do not depend on it)"; else bad "S7 gitleaks emits no Severity field (scripts do not depend on it)"; fi

    # End-to-end: the real script.sh with the real gitleaks against the planted project
    E="$TEST_ROOT/e2e"
    mkdir -p "$E/tmp" "$E/bin"
    make_stubs "$E/bin"; rm -f "$E/bin/gitleaks"
    mkdir -p "$E/proj" && git -C "$E/proj" init -q 2>/dev/null
    echo "API_TOKEN=$FAKE_GH_TOKEN" > "$E/proj/.env"
    ( cd "$E/proj" && env PATH="$E/bin:$GL_DIR:/usr/bin:/bin" TMPDIR="$E/tmp" "$BASH_BIN" "$SCRIPT_SH" ) > "$E/out.txt" 2>&1 < /dev/null
    assert_eq "S1 e2e: real gitleaks + planted .env => script.sh exits 1" "1" "$?"
    assert_contains "S1 e2e: console reports detection" "$E/out.txt" "secret(s) detected"
    assert_not_contains "S4 e2e: console has no raw token" "$E/out.txt" "$FAKE_BODY"
    assert_not_contains "S4 e2e: markdown has no raw token" "$E/proj/.hook-reports/security-scan-report.md" "$FAKE_BODY"
    assert_not_contains "S4 e2e: JSON report has no raw token (--redact)" "$E/proj/.hook-reports/gitleaks-report.json" "$FAKE_BODY"
    assert_eq "S4 e2e: JSON report mode" "600" "$(file_mode "$E/proj/.hook-reports/gitleaks-report.json")"

    rm -f "$E/proj/.env"
    ( cd "$E/proj" && env PATH="$E/bin:$GL_DIR:/usr/bin:/bin" TMPDIR="$E/tmp" "$BASH_BIN" "$SCRIPT_SH" ) > "$E/out2.txt" 2>&1 < /dev/null
    assert_eq "S1 e2e: real gitleaks + clean project => exit 0" "0" "$?"
fi

section "S7 .mobsf"
if grep -Eq '^[[:space:]]*-[[:space:]]*"?(google-services\.json|GoogleService-Info\.plist|\.env\*)"?' "$MOBSF_CFG"; then
    bad ".mobsf no longer ignores credential-bearing filenames"
else
    ok ".mobsf no longer ignores credential-bearing filenames"
fi

# ─── Summary ───────────────────────────────────────────────────────────────

echo ""
echo "================================================================"
echo " Preset script tests: PASS $PASS  FAIL $FAIL  SKIP $SKIP"
echo "================================================================"
[ "$FAIL" -eq 0 ]
