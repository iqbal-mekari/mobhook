#!/bin/bash
# =============================================================================
# CI Security Scan — Centralized Edition
# =============================================================================
# Runs gitleaks (secret detection) + mobsfscan (mobile security patterns)
# Produces JSON reports for downstream consumers (Jenkins, webhooks, etc.)
#
# Usage:
#   SCAN_DIR=/path/to/project ./ci-security-scan.sh          # scan specific project
#
# Config resolution:
#   1. CONFIG_DIR env var (explicit override)
#   2. Same directory as this script (default — mobhook preset layout)
#
# Output:
#   .hook-reports/gitleaks-report.json    — gitleaks findings
#   .hook-reports/mobsfscan-report.json   — mobsfscan findings
#   .hook-reports/scan-summary.json       — machine-readable summary for Jenkins
#
# Required tools: gitleaks, mobsfscan, jq
# =============================================================================
set -euo pipefail

# ─── Environment Configuration ──────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN_DIR="${SCAN_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo ".")}"
PROJECT_NAME="${PROJECT_NAME:-$(basename "$SCAN_DIR")}"
BRANCH_NAME="${BRANCH_NAME:-${GIT_BRANCH:-$(git -C "$SCAN_DIR" branch --show-current 2>/dev/null || echo "unknown")}}"
COMMIT_SHA="${COMMIT_SHA:-${GIT_COMMIT:-$(git -C "$SCAN_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")}}"

# Config files (gitleaks.toml, .mobsf) live alongside this script in the preset dir
CONFIG_DIR="${CONFIG_DIR:-${SCRIPT_DIR}}"
CONFIG_DIR="$(cd "$CONFIG_DIR" 2>/dev/null && pwd || echo "$CONFIG_DIR")"

# Report output
REPORT_DIR="${SCAN_DIR}/.hook-reports"
GITLEAKS_JSON="$REPORT_DIR/gitleaks-report.json"
MOBSFSCAN_JSON="$REPORT_DIR/mobsfscan-report.json"
mkdir -p "$REPORT_DIR"

PROJECT_SLUG="${PROJECT_SLUG:-$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//')}"

# ─── Tool Check + Auto-Install ──────────────────────────────────────────────

require_tool() {
    local tool="$1"
    local install_cmd="$2"

    if command -v "$tool" &>/dev/null; then
        return 0
    fi

    echo "[Install] $tool not found, installing..."
    if eval "$install_cmd" 2>&1 && command -v "$tool" &>/dev/null; then
        echo "  ✅ $tool installed"
    else
        echo "[FATAL] $tool installation failed. Install manually: $install_cmd"
        exit 1
    fi
}

require_tool gitleaks "brew install gitleaks"
require_tool jq "brew install jq"

# semgrep: required by mobsfscan for semantic pattern scanning
# brew formula is 229MB and unreliable on CI; prefer pipx
if ! command -v semgrep &>/dev/null; then
    echo "[Install] semgrep not found, installing via pipx..."
    pipx install semgrep 2>&1
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v semgrep &>/dev/null; then
        echo "  pipx failed, falling back to brew..."
        brew install semgrep 2>&1
    fi
    if ! command -v semgrep &>/dev/null; then
        echo "[FATAL] semgrep installation failed. Install manually: brew install semgrep"
        exit 1
    fi
    echo "  ✅ semgrep installed"
fi

# mobsfscan: requires Python ≤3.13 (pydantic-core/pyo3 not yet compatible with 3.14+)
# Use pipx with an explicit compatible Python.
if ! command -v pipx &>/dev/null; then
    echo "[Install] pipx not found, installing..."
    brew install pipx
    export PATH="$HOME/.local/bin:$PATH"
fi

if ! command -v mobsfscan &>/dev/null || ! mobsfscan --version &>/dev/null; then
    if command -v mobsfscan &>/dev/null; then
        echo "[Install] mobsfscan binary found but non-functional, reinstalling..."
        pipx uninstall mobsfscan 2>/dev/null || true
    fi
    echo "[Install] mobsfscan not found, finding compatible Python (≤3.13)..."

    PYTHON_BIN=""

    # If pyenv is available, resolve actual binary from pyenv versions (not shims)
    if command -v pyenv &>/dev/null; then
        for ver in 3.13 3.12 3.11; do
            pyenv_ver=$(pyenv versions --bare 2>/dev/null | grep "^${ver}\." | sort -rV | head -1)
            if [ -n "$pyenv_ver" ]; then
                candidate="$(pyenv root)/versions/${pyenv_ver}/bin/python3"
                if [ -x "$candidate" ]; then
                    PYTHON_BIN="$candidate"
                    echo "  Found via pyenv: $PYTHON_BIN ($pyenv_ver)"
                    break
                fi
            fi
        done
    fi

    # Fallback: look for versioned binaries on PATH (non-pyenv)
    if [ -z "$PYTHON_BIN" ]; then
        for ver in python3.13 python3.12 python3.11; do
            if bin=$(command -v "$ver" 2>/dev/null) && "$bin" --version &>/dev/null; then
                PYTHON_BIN="$bin"
                echo "  Found on PATH: $PYTHON_BIN"
                break
            fi
        done
    fi

    # Last resort: install python@3.13 via brew
    if [ -z "$PYTHON_BIN" ]; then
        echo "  No compatible Python found, installing python@3.13 via brew..."
        brew install python@3.13
        PYTHON_BIN="$(brew --prefix python@3.13)/bin/python3.13"
    fi

    echo "[Install] Installing mobsfscan via pipx --python $PYTHON_BIN..."
    pipx install mobsfscan --python "$PYTHON_BIN" 2>/dev/null || \
        pipx reinstall mobsfscan --python "$PYTHON_BIN"
    export PATH="$HOME/.local/bin:$PATH"

    if ! command -v mobsfscan &>/dev/null; then
        echo "[FATAL] mobsfscan installation failed."
        exit 1
    fi
    echo "  ✅ mobsfscan installed"
fi

# ─── Validate Config ────────────────────────────────────────────────────────

echo "=========================================="
echo " CI Security Scan"
echo "=========================================="
echo " Project : $PROJECT_NAME"
echo " Branch  : $BRANCH_NAME"
echo " Commit  : $COMMIT_SHA"
echo " Config  : $CONFIG_DIR"
echo " Scan Dir: $SCAN_DIR"
echo "=========================================="
echo ""

if [ ! -f "$CONFIG_DIR/gitleaks.toml" ]; then
    echo "[WARN] gitleaks.toml not found at $CONFIG_DIR — using defaults"
fi
if [ ! -f "$CONFIG_DIR/.mobsf" ]; then
    echo "[WARN] .mobsf not found at $CONFIG_DIR — using defaults"
fi

# ─── Counters ───────────────────────────────────────────────────────────────

TOTAL_FAILURES=0
GITLEAKS_ISSUES=0
MOBSFSCAN_ISSUES=0
GITLEAKS_SEVERITY_SUMMARY="{}"
MOBSFSCAN_SEVERITY_SUMMARY="{}"
OVERALL_SEVERITY="none"

# ─── [1/2] Gitleaks — Secret Detection ──────────────────────────────────────

echo "[1/2] Gitleaks — Secret Detection..."
GL_START=$(date +%s)

GITLEAKS_EXIT=0
if [ -f "$CONFIG_DIR/gitleaks.toml" ]; then
    gitleaks detect --source "$SCAN_DIR" \
        --config "$CONFIG_DIR/gitleaks.toml" \
        --no-git \
        --report-path "$GITLEAKS_JSON" \
        --report-format json 2>&1 || GITLEAKS_EXIT=$?
else
    gitleaks detect --source "$SCAN_DIR" \
        --no-git \
        --report-path "$GITLEAKS_JSON" \
        --report-format json 2>&1 || GITLEAKS_EXIT=$?
fi

# Parse results
GITLEAKS_SUMMARY="No findings."
if [ -s "$GITLEAKS_JSON" ]; then
    GITLEAKS_ISSUES=$(jq 'length' "$GITLEAKS_JSON" 2>/dev/null || echo "0")
    GITLEAKS_SEVERITY_SUMMARY=$(jq -r 'group_by(.Severity // "UNKNOWN") | map({key: .[0].Severity // "UNKNOWN", value: length}) | from_entries' "$GITLEAKS_JSON" 2>/dev/null || echo "{}")
    if [ "$GITLEAKS_ISSUES" -gt 0 ]; then
        GITLEAKS_SUMMARY=$(jq -r '[.[] | "• \(.RuleID) — \(.File | split("/") | .[-1]):\(.StartLine)"] | .[0:5] | join("\n")' "$GITLEAKS_JSON" 2>/dev/null || echo "See full report.")
        if [ "$GITLEAKS_ISSUES" -gt 5 ]; then
            GITLEAKS_SUMMARY="${GITLEAKS_SUMMARY}\n... and $((GITLEAKS_ISSUES - 5)) more"
        fi
    fi
fi

if [ "$GITLEAKS_ISSUES" -gt 0 ]; then
    echo "  ❌ $GITLEAKS_ISSUES secret(s) detected"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    echo ""
    echo "  ┌─ Findings ─────────────────────────────────────────────────────────"
    jq -r '
        to_entries | map(.value + {_index: (.key + 1)}) | .[] |
        "  │ [\(._index)] \(.RuleID)",
        "  │     File  : \(.File):\(.StartLine)",
        "  │     Match : \(.Match | if length > 80 then .[0:80] + "…" else . end)",
        "  │"
    ' "$GITLEAKS_JSON" 2>/dev/null || true
    echo "  └────────────────────────────────────────────────────────────────────"
else
    echo "  ✅ No secrets found"
fi

GL_END=$(date +%s)
GL_DURATION=$((GL_END - GL_START))
echo ""

# ─── [2/2] mobsfscan — Mobile Security Patterns ────────────────────────────

echo "[2/2] mobsfscan — Mobile Security Patterns..."
MS_START=$(date +%s)

MOBSFSCAN_EXIT=0
MOBSFSCAN_STDERR="$REPORT_DIR/mobsfscan-stderr.log"
if [ -f "$CONFIG_DIR/.mobsf" ]; then
    mobsfscan "$SCAN_DIR" --config "$CONFIG_DIR/.mobsf" --json > "$MOBSFSCAN_JSON" 2>"$MOBSFSCAN_STDERR" || MOBSFSCAN_EXIT=$?
else
    mobsfscan "$SCAN_DIR" --json > "$MOBSFSCAN_JSON" 2>"$MOBSFSCAN_STDERR" || MOBSFSCAN_EXIT=$?
fi

# Show any stderr output (warnings, parse errors) for visibility in CI logs
if [ -s "$MOBSFSCAN_STDERR" ]; then
    echo "  [mobsfscan stderr]:"
    cat "$MOBSFSCAN_STDERR"
fi

if [ "$MOBSFSCAN_EXIT" -ne 0 ] && [ ! -s "$MOBSFSCAN_JSON" ]; then
    echo "  ⚠️  mobsfscan exited with code $MOBSFSCAN_EXIT and produced no JSON — scan may have failed"
fi

# Parse results — mobsfscan uses {results: {rule_id: {metadata: {severity}, files: [...]}}}
MOBSFSCAN_SUMMARY="No findings."
if [ -s "$MOBSFSCAN_JSON" ]; then
    MOBSFSCAN_ISSUES=$(jq 'if type == "object" and has("results") then
        [.results | to_entries[] | select(.value.files != null) | .value.files | length] | add // 0
    elif type == "array" then length else 0 end' "$MOBSFSCAN_JSON" 2>/dev/null || echo "0")

    MOBSFSCAN_SEVERITY_SUMMARY=$(jq -r '
        if type == "object" and has("results") then
            [.results | to_entries[] | select(.value.files != null)] |
            group_by(.value.metadata.severity // "UNKNOWN") |
            map({key: (.[0].value.metadata.severity // "UNKNOWN"), value: (map(.value.files | length) | add)}) |
            from_entries
        else {} end
    ' "$MOBSFSCAN_JSON" 2>/dev/null || echo "{}")

    if [ "$MOBSFSCAN_ISSUES" -gt 0 ]; then
        MOBSFSCAN_SUMMARY=$(jq -r 'if type == "object" and has("results") then
            [.results | to_entries[] | select(.value.files != null) |
            .key as $rule | .value.metadata.severity as $sev |
            .value.files[]? |
            "• [\($sev // "INFO")] \($rule) — \(.file_path | split("/") | .[-1]):\(.match_lines[0])"]
            | .[0:5] | join("\n")
        else "See full report." end' "$MOBSFSCAN_JSON" 2>/dev/null || echo "See full report.")
        if [ "$MOBSFSCAN_ISSUES" -gt 5 ]; then
            MOBSFSCAN_SUMMARY="${MOBSFSCAN_SUMMARY}\n... and $((MOBSFSCAN_ISSUES - 5)) more"
        fi
    fi
fi

if [ "$MOBSFSCAN_ISSUES" -gt 0 ]; then
    echo "  ❌ $MOBSFSCAN_ISSUES issue(s) detected"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    echo ""
    echo "  ┌─ Findings ─────────────────────────────────────────────────────────"
    jq -r '
        if type == "object" and has("results") then
            [.results | to_entries[] | select(.value.files != null) |
                .key as $rule | .value.metadata as $meta | .value.files[]? |
                {rule: $rule, sev: ($meta.severity // "INFO"), file: .file_path,
                 line: .match_lines[0], match: (.match_string // ""),
                 cwe: ($meta.cwe // ""), desc: ($meta.description // "")}
            ] | to_entries | .[] | .value as $f | .key as $i |
            "  │ [\($i + 1)] [\($f.sev)] \($f.rule)",
            "  │     File  : \($f.file):\($f.line)",
            (if $f.match != "" then "  │     Match : \($f.match | if length > 80 then .[0:80] + "…" else . end)" else empty end),
            (if $f.cwe != "" then "  │     CWE   : \($f.cwe)" else empty end),
            "  │"
        else empty end
    ' "$MOBSFSCAN_JSON" 2>/dev/null || true
    echo "  └────────────────────────────────────────────────────────────────────"
else
    echo "  ✅ No issues found"
fi

MS_END=$(date +%s)
MS_DURATION=$((MS_END - MS_START))
echo ""

# ─── Determine Overall Severity ─────────────────────────────────────────────

TOTAL_ISSUES=$((GITLEAKS_ISSUES + MOBSFSCAN_ISSUES))
if [ "$TOTAL_FAILURES" -gt 0 ]; then
    HAS_CRITICAL=$(echo "$GITLEAKS_SEVERITY_SUMMARY $MOBSFSCAN_SEVERITY_SUMMARY" | jq -r 'if has("ERROR") or has("CRITICAL") or has("HIGH") then "yes" else "no" end' 2>/dev/null || echo "no")
    HAS_WARNING=$(echo "$GITLEAKS_SEVERITY_SUMMARY $MOBSFSCAN_SEVERITY_SUMMARY" | jq -r 'if has("WARNING") or has("MEDIUM") then "yes" else "no" end' 2>/dev/null || echo "no")
    if [ "$HAS_CRITICAL" = "yes" ]; then
        OVERALL_SEVERITY="critical"
    elif [ "$HAS_WARNING" = "yes" ]; then
        OVERALL_SEVERITY="high"
    else
        OVERALL_SEVERITY="high"
    fi
fi

SCAN_STATUS="pass"
[ "$TOTAL_FAILURES" -gt 0 ] && SCAN_STATUS="fail"

TOTAL_DURATION=$((GL_DURATION + MS_DURATION))

echo "=========================================="
echo " Result: $( [ $TOTAL_FAILURES -eq 0 ] && echo '✅ PASS' || echo '❌ FAIL' )"
echo " Issues: $TOTAL_ISSUES ($GITLEAKS_ISSUES gitleaks, $MOBSFSCAN_ISSUES mobsfscan)"
echo " Duration: ${TOTAL_DURATION}s"
echo "=========================================="

# ─── Generate Machine-Readable Summary ──────────────────────────────────────
# Jenkinsfile / webhook consumers read this to build notifications with scan details

SUMMARY_JSON="$REPORT_DIR/scan-summary.json"

jq -n \
    --arg project "$PROJECT_NAME" \
    --arg branch "$BRANCH_NAME" \
    --arg commit "$COMMIT_SHA" \
    --arg status "$SCAN_STATUS" \
    --arg severity "$OVERALL_SEVERITY" \
    --argjson totalIssues "$TOTAL_ISSUES" \
    --argjson totalFailures "$TOTAL_FAILURES" \
    --argjson gitleaksIssues "$GITLEAKS_ISSUES" \
    --argjson mobsfscanIssues "$MOBSFSCAN_ISSUES" \
    --argjson gitleaksDuration "$GL_DURATION" \
    --argjson mobsfscanDuration "$MS_DURATION" \
    --argjson totalDuration "$TOTAL_DURATION" \
    --arg gitleaksSummary "$GITLEAKS_SUMMARY" \
    --arg mobsfscanSummary "$MOBSFSCAN_SUMMARY" \
    --argjson gitleaksSeverity "$GITLEAKS_SEVERITY_SUMMARY" \
    --argjson mobsfscanSeverity "$MOBSFSCAN_SEVERITY_SUMMARY" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
        project: $project,
        branch: $branch,
        commit: $commit,
        status: $status,
        severity: $severity,
        totalIssues: $totalIssues,
        totalFailures: $totalFailures,
        gitleaks: {
            issues: $gitleaksIssues,
            duration: $gitleaksDuration,
            summary: $gitleaksSummary,
            severityBreakdown: $gitleaksSeverity
        },
        mobsfscan: {
            issues: $mobsfscanIssues,
            duration: $mobsfscanDuration,
            summary: $mobsfscanSummary,
            severityBreakdown: $mobsfscanSeverity
        },
        totalDuration: $totalDuration,
        timestamp: $timestamp
    }' > "$SUMMARY_JSON"

echo ""
echo "📄 Reports:"
echo "   ├── .hook-reports/gitleaks-report.json"
echo "   ├── .hook-reports/mobsfscan-report.json"
echo "   └── .hook-reports/scan-summary.json"
echo ""

# ─── Exit ───────────────────────────────────────────────────────────────────
# Always exit 0 — the scan itself succeeded regardless of findings.
# The notification and scan-summary.json communicate pass/fail status.
exit 0
