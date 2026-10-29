#!/bin/bash
# =============================================================================
# Mobile Security Scan Script
# =============================================================================
# Runs gitleaks and mobsfscan security scans
# Designed to run as part of the hook dispatcher (via .d/ directory)
#
# Privacy Guarantee: All scanning happens locally. No data leaves your machine.
#
# Error handling scheme (explicit, fail closed):
#   - `set -uo pipefail` is on; `set -e` is deliberately OFF because the scan must
#     always reach report generation. Every command whose failure matters is
#     checked explicitly (if / ||) and feeds TOTAL_FAILURES.
#   - A scanner that exits non-zero is ALWAYS a failure, whether or not it
#     produced a parseable report (a crashed scanner must not pass the gate).
#   - Counters use TOTAL_FAILURES=$((TOTAL_FAILURES + 1)) (never ((x++)), which
#     returns 1 when x is 0).
#
# Secrets handling:
#   - gitleaks always runs with --redact; raw Match/Secret values are never
#     printed to the console or written to the markdown report.
#   - Reports are created with umask 077 and chmod 600.
#   - Temp files live in a private mktemp -d directory removed on EXIT/INT/TERM.
#
# Optional environment:
#   MOBSFSCAN_VERSION  Pin the pip install of mobsfscan (pip3 install mobsfscan==X).
#                      Exact versions are UNVERIFIED here; supply your own.
# =============================================================================

set -uo pipefail
umask 077

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory — config files (gitleaks.toml, .mobsf) live alongside this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use git to find the actual project root (fail closed if not in a repository)
PROJECT_ROOT="$(git rev-parse --show-toplevel)" || {
    echo -e "${RED}❌ Not inside a git repository — cannot determine project root${NC}" >&2
    exit 1
}

# =============================================================================
# TEMP FILES (private directory, always cleaned up)
# =============================================================================

WORK_DIR=""
cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# mktemp -d creates the directory with mode 0700
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mobhook-security.XXXXXX")" || {
    echo -e "${RED}❌ Could not create a private temp directory${NC}" >&2
    exit 1
}

# =============================================================================
# REPORT SETUP
# =============================================================================

REPORT_DIR="$PROJECT_ROOT/.hook-reports"
REPORT_FILE="$REPORT_DIR/security-scan-report.md"
GITLEAKS_JSON="$REPORT_DIR/gitleaks-report.json"
MOBSFSCAN_JSON="$REPORT_DIR/mobsfscan-report.json"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
TOTAL_FAILURES=0

# Create reports directory (umask 077 => 0700 when newly created)
mkdir -p "$REPORT_DIR" || {
    echo -e "${RED}❌ Could not create reports directory: $REPORT_DIR${NC}" >&2
    exit 1
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# jq prelude: sanitize a value for use inside a markdown table cell.
# Strips pipes, backticks, CR and LF so scanned file names / rule ids / text
# cannot break out of the table or inject markdown.
JQ_MD='def md: (. // "") | tostring | gsub("[|`\\r\\n]"; " ");'

# Restrict report files to the owner (they describe where secrets live)
secure_reports() {
    chmod 600 "$REPORT_FILE" "$GITLEAKS_JSON" "$MOBSFSCAN_JSON" 2>/dev/null || true
}

# Prints "name" or "name==version" when a version pin is supplied.
# Exact versions are UNVERIFIED: the caller supplies them via env vars.
pin_spec() {
    local name="$1"
    local version="${2:-}"
    if [ -z "$version" ]; then
        echo "$name"
        return 0
    fi
    case "$version" in
        *[!A-Za-z0-9._+!-]*)
            echo "invalid version string for $name" >&2
            return 1
            ;;
    esac
    echo "${name}==${version}"
}

# Installers (invoked by function name — never built from command strings)
install_gitleaks() {
    # Homebrew formula is unpinned (no verified per-version formula); see header.
    brew install gitleaks
}

install_mobsfscan() {
    local spec
    spec="$(pin_spec mobsfscan "${MOBSFSCAN_VERSION:-}")" || return 1
    pip3 install "$spec"
}

# Convert severity to emoji
severity_emoji() {
    case "$1" in
        CRITICAL|critical) echo "🔴" ;;
        HIGH|high) echo "🟠" ;;
        MEDIUM|medium) echo "🟡" ;;
        LOW|low) echo "🟢" ;;
        WARNING|warning) echo "⚠️" ;;
        ERROR|error) echo "❌" ;;
        INFO|info) echo "ℹ️" ;;
        *) echo "⚪" ;;
    esac
}

# Checks if a tool is installed; if not, interactively prompts to install it.
# Usage: check_and_install_tool <tool> <installer_function> <label>
# The installer is a function NAME (never a command string).
# Returns 0 if the tool is available (already present or just installed), 1 otherwise.
check_and_install_tool() {
    local tool="$1"
    local install_fn="$2"
    local install_label="$3"

    if command -v "$tool" &> /dev/null; then
        echo -e "${GREEN}  ✅ $tool found${NC}"
        return 0
    fi

    echo -e "${YELLOW}  ⚠️  $tool not found${NC}"

    if [ -t 0 ]; then
        echo -e "${CYAN}     Install command: $install_label${NC}"
        printf "${CYAN}     Install now? [y/N]: ${NC}"
        read -r answer </dev/tty
        case "$answer" in
            [Yy]|[Yy][Ee][Ss])
                echo -e "${BLUE}     Installing $tool...${NC}"
                "$install_fn" || true
                if command -v "$tool" &> /dev/null; then
                    echo -e "${GREEN}     ✅ $tool installed successfully${NC}"
                    return 0
                else
                    echo -e "${RED}     ❌ Installation failed. Install manually: $install_label${NC}"
                    return 1
                fi
                ;;
            *)
                echo -e "${YELLOW}     Skipping — $tool scan will be skipped${NC}"
                return 1
                ;;
        esac
    else
        echo -e "${YELLOW}     Non-interactive session — install manually: $install_label${NC}"
        return 1
    fi
}

# =============================================================================
# TOOL CHECK
# =============================================================================

echo -e "${BLUE}🔍 Checking required tools...${NC}"
GITLEAKS_AVAILABLE=true
MOBSFSCAN_AVAILABLE=true

check_and_install_tool "gitleaks" install_gitleaks "brew install gitleaks" \
    || GITLEAKS_AVAILABLE=false
check_and_install_tool "mobsfscan" install_mobsfscan "pip install mobsfscan" \
    || MOBSFSCAN_AVAILABLE=false

echo ""

# =============================================================================
# MAIN EXECUTION
# =============================================================================

echo -e "${BLUE}🔒 mobhook Security Scan${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}📄 Reports directory: .hook-reports/${NC}"
echo -e "${BLUE}📄 Combined report: .hook-reports/security-scan-report.md${NC}"
echo ""

# =============================================================================
# GITLEAKS: Secret Detection (Scans entire codebase)
# =============================================================================

echo -e "${BLUE}[1/2] Running Gitleaks — Secret Detection...${NC}"
GITLEAKS_START=$(date +%s)
GITLEAKS_STATUS="✅ Pass"
GITLEAKS_ISSUES=0
GITLEAKS_EXIT_CODE=0
GITLEAKS_REPORT_OK=true
GITLEAKS_SCAN_ERROR=false

# Initialize empty JSON array (also clears any stale report from a previous run)
echo "[]" > "$GITLEAKS_JSON"

if $GITLEAKS_AVAILABLE; then
    # --redact: gitleaks masks Match/Secret in its stdout and JSON report
    GITLEAKS_ARGS=(detect --source "$PROJECT_ROOT" --no-git --redact \
        --report-path "$GITLEAKS_JSON" --report-format json)
    if [ -f "$SCRIPT_DIR/gitleaks.toml" ]; then
        GITLEAKS_ARGS+=(--config "$SCRIPT_DIR/gitleaks.toml")
    fi

    # No pipe: $? is gitleaks' own exit code (a pipe to tee would mask it)
    gitleaks "${GITLEAKS_ARGS[@]}" 2>&1
    GITLEAKS_EXIT_CODE=$?

    # Count issues from JSON; an unreadable report is itself a problem
    GITLEAKS_COUNT=""
    if [ -s "$GITLEAKS_JSON" ]; then
        GITLEAKS_COUNT=$(jq 'if type == "array" then length else error("not an array") end' "$GITLEAKS_JSON" 2>/dev/null) || GITLEAKS_COUNT=""
    fi
    case "$GITLEAKS_COUNT" in
        ''|*[!0-9]*) GITLEAKS_REPORT_OK=false ;;
        *) GITLEAKS_ISSUES=$GITLEAKS_COUNT ;;
    esac

    if [ "$GITLEAKS_EXIT_CODE" -ne 0 ]; then
        # Non-zero exit is always a failure (fail closed)
        GITLEAKS_STATUS="❌ Fail"
        TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
        if [ "$GITLEAKS_REPORT_OK" = true ] && [ "$GITLEAKS_ISSUES" -gt 0 ]; then
            echo -e "${RED}❌ Gitleaks: $GITLEAKS_ISSUES secret(s) detected!${NC}"
        else
            GITLEAKS_SCAN_ERROR=true
            echo -e "${RED}❌ Gitleaks: scan failed (exit code $GITLEAKS_EXIT_CODE) with no usable findings report — treated as failure${NC}"
        fi
    elif [ "$GITLEAKS_REPORT_OK" != true ]; then
        GITLEAKS_STATUS="❌ Fail"
        GITLEAKS_SCAN_ERROR=true
        TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
        echo -e "${RED}❌ Gitleaks: report missing or unparseable (is jq installed?) — treated as failure${NC}"
    elif [ "$GITLEAKS_ISSUES" -gt 0 ]; then
        echo -e "${YELLOW}⚠️  Gitleaks: $GITLEAKS_ISSUES warning(s)${NC}"
        GITLEAKS_STATUS="⚠️ Warnings"
    else
        echo -e "${GREEN}✅ Gitleaks: No secrets found${NC}"
    fi
else
    GITLEAKS_STATUS="⚠️ Skipped"
fi

GITLEAKS_END=$(date +%s)
GITLEAKS_DURATION=$((GITLEAKS_END - GITLEAKS_START))

echo ""

# =============================================================================
# MOBSFSCAN: Mobile-Specific Security Patterns
# =============================================================================

echo -e "${BLUE}[2/2] Running mobsfscan — Mobile Security Patterns...${NC}"
MOBSFSCAN_START=$(date +%s)
MOBSFSCAN_STATUS="✅ Pass"
MOBSFSCAN_ISSUES=0
MOBSFSCAN_EXIT_CODE=0
MOBSFSCAN_SCAN_ERROR=false

# Initialize empty JSON
echo '{"findings": []}' > "$MOBSFSCAN_JSON"

if $MOBSFSCAN_AVAILABLE; then
    MOBSFSCAN_ARGS=("$PROJECT_ROOT")
    if [ -f "$SCRIPT_DIR/.mobsf" ]; then
        MOBSFSCAN_ARGS+=(--config "$SCRIPT_DIR/.mobsf")
    fi
    MOBSFSCAN_ARGS+=(--json)

    # Run mobsfscan - warnings go to stderr (private temp file), JSON to stdout
    mobsfscan "${MOBSFSCAN_ARGS[@]}" > "$MOBSFSCAN_JSON" 2>"$WORK_DIR/mobsfscan-warnings.txt"
    MOBSFSCAN_EXIT_CODE=$?

    # Display warnings if any
    if [ -s "$WORK_DIR/mobsfscan-warnings.txt" ]; then
        head -10 "$WORK_DIR/mobsfscan-warnings.txt"
    fi

    # Display summary
    if [ -s "$MOBSFSCAN_JSON" ]; then
        # Try to parse and display results
        if jq -e 'type == "object" and has("results")' "$MOBSFSCAN_JSON" > /dev/null 2>&1; then
            # New mobsfscan format with results object
            jq -r '.results | to_entries[] | select(.value.files != null or .value.metadata != null) | "\(.key): \(.value.metadata.severity // "INFO")"' "$MOBSFSCAN_JSON" 2>/dev/null | head -20

            # Count actual issues (those with files = findings)
            MOBSFSCAN_ISSUES=$(jq '[.results | to_entries[] | select(.value.files != null) | .value.files | length] | add // 0' "$MOBSFSCAN_JSON" 2>/dev/null || echo "0")
        else
            # Array format
            jq -r '.[] | "[\(.severity)] \(.id) - \(.file // "N/A")"' "$MOBSFSCAN_JSON" 2>/dev/null | head -20
            MOBSFSCAN_ISSUES=$(jq 'length' "$MOBSFSCAN_JSON" 2>/dev/null || echo "0")
        fi
    fi

    case "$MOBSFSCAN_ISSUES" in
        ''|*[!0-9]*) MOBSFSCAN_ISSUES=0 ;;
    esac

    if [ "$MOBSFSCAN_EXIT_CODE" -ne 0 ] && [ "$MOBSFSCAN_ISSUES" -gt 0 ]; then
        echo -e "${RED}❌ mobsfscan: $MOBSFSCAN_ISSUES issue(s) detected!${NC}"
        MOBSFSCAN_STATUS="❌ Fail"
        TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    elif [ "$MOBSFSCAN_EXIT_CODE" -ne 0 ]; then
        # Non-zero exit with nothing parseable = the scanner itself failed (fail closed)
        echo -e "${RED}❌ mobsfscan: scan failed (exit code $MOBSFSCAN_EXIT_CODE) with no usable findings — treated as failure${NC}"
        MOBSFSCAN_STATUS="❌ Fail"
        MOBSFSCAN_SCAN_ERROR=true
        TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    elif [ "$MOBSFSCAN_ISSUES" -gt 0 ]; then
        echo -e "${YELLOW}⚠️  mobsfscan: $MOBSFSCAN_ISSUES warning(s)${NC}"
        MOBSFSCAN_STATUS="⚠️ Warnings"
    else
        echo -e "${GREEN}✅ mobsfscan: No issues found${NC}"
    fi
else
    MOBSFSCAN_STATUS="⚠️ Skipped"
fi

MOBSFSCAN_END=$(date +%s)
MOBSFSCAN_DURATION=$((MOBSFSCAN_END - MOBSFSCAN_START))

# =============================================================================
# GENERATE COMBINED MARKDOWN REPORT
# =============================================================================

cat > "$REPORT_FILE" << EOF
# Security Scan Report

**Generated:** $TIMESTAMP
**Project:** $(basename "$PROJECT_ROOT")
**Branch:** $(git branch --show-current 2>/dev/null || echo "unknown")
**Commit:** $(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

---

## 📊 Summary

| Tool | Status | Issues | Duration |
|------|--------|--------|----------|
| Gitleaks | $GITLEAKS_STATUS | $GITLEAKS_ISSUES | ${GITLEAKS_DURATION}s |
| mobsfscan | $MOBSFSCAN_STATUS | $MOBSFSCAN_ISSUES | ${MOBSFSCAN_DURATION}s |

**Result:** $(if [ $TOTAL_FAILURES -eq 0 ]; then echo "✅ All checks passed"; else echo "❌ $TOTAL_FAILURES tool(s) failed"; fi)

---

## 📄 Raw Reports

| Report | Format | Location |
|--------|--------|----------|
| Gitleaks | JSON | \`.hook-reports/gitleaks-report.json\` |
| mobsfscan | JSON | \`.hook-reports/mobsfscan-report.json\` |

---

EOF

# =============================================================================
# GITLEAKS DETAILED SECTION
# =============================================================================

cat >> "$REPORT_FILE" << 'EOF'
## 🔐 Gitleaks - Secret Detection

EOF

if [ "$GITLEAKS_STATUS" = "⚠️ Skipped" ]; then
    cat >> "$REPORT_FILE" << EOF
**Status:** Tool not installed

\`\`\`
Install with: brew install gitleaks
\`\`\`

EOF
elif [ "$GITLEAKS_SCAN_ERROR" = true ]; then
    cat >> "$REPORT_FILE" << EOF
**Status:** $GITLEAKS_STATUS

❌ The scan failed or produced no usable report (gitleaks exit code: $GITLEAKS_EXIT_CODE). Treated as a failure.

EOF
elif [ "$GITLEAKS_ISSUES" -gt 0 ]; then
    cat >> "$REPORT_FILE" << EOF
**Status:** $GITLEAKS_STATUS
**Issues Found:** $GITLEAKS_ISSUES

### Findings

| # | Rule | Severity | File | Line | Match (masked) |
|---|------|----------|------|------|----------------|
EOF

    # Secret values are never written to the markdown report; cells are sanitized
    jq -r "$JQ_MD"'to_entries | .[] | "| \(.key + 1) | \(.value.RuleID | md) | \(.value.severity // "N/A" | md) | \(.value.File | md) | \(.value.StartLine | md) | [REDACTED]"' "$GITLEAKS_JSON" 2>/dev/null | head -50 >> "$REPORT_FILE"

    if [ "$GITLEAKS_ISSUES" -gt 50 ]; then
        echo "" >> "$REPORT_FILE"
        echo "*... and $(($GITLEAKS_ISSUES - 50)) more findings. See full JSON report for details.*" >> "$REPORT_FILE"
    fi

else
    cat >> "$REPORT_FILE" << EOF
**Status:** $GITLEAKS_STATUS
**Issues Found:** 0

✅ No secrets or credentials detected in the codebase.

EOF
fi

echo "---" >> "$REPORT_FILE"

# =============================================================================
# MOBSFSCAN DETAILED SECTION
# =============================================================================

cat >> "$REPORT_FILE" << 'EOF'

## 📱 mobsfscan - Mobile Security Patterns

EOF

if [ "$MOBSFSCAN_STATUS" = "⚠️ Skipped" ]; then
    cat >> "$REPORT_FILE" << EOF
**Status:** Tool not installed

\`\`\`
Install with: pip install mobsfscan
\`\`\`

EOF
elif [ "$MOBSFSCAN_SCAN_ERROR" = true ]; then
    cat >> "$REPORT_FILE" << EOF
**Status:** $MOBSFSCAN_STATUS

❌ The scan failed or produced no usable report (mobsfscan exit code: $MOBSFSCAN_EXIT_CODE). Treated as a failure.

EOF
elif [ "$MOBSFSCAN_ISSUES" -gt 0 ]; then
    cat >> "$REPORT_FILE" << EOF
**Status:** $MOBSFSCAN_STATUS
**Issues Found:** $MOBSFSCAN_ISSUES

### Findings

EOF

    # Handle new mobsfscan format with results object
    if jq -e 'type == "object" and has("results")' "$MOBSFSCAN_JSON" > /dev/null 2>&1; then
        cat >> "$REPORT_FILE" << 'TABLEHEAD'
| # | Rule ID | Severity | File | Line | Match (masked) |
|---|---------|----------|------|------|----------------|
TABLEHEAD

        # Matched source text is never written to the report; cells are sanitized
        jq -r "$JQ_MD"'.results | to_entries[] | select(.value.files != null) | .key as $rule | .value.metadata.severity as $sev | .value.files[]? | "| | \($rule | md) | \($sev // "INFO" | md) | \(.file_path | tostring | split("/") | .[-1] | md) | \(.match_lines[0] | md) | [REDACTED]"' "$MOBSFSCAN_JSON" 2>/dev/null | head -100 >> "$REPORT_FILE"

        if [ "$MOBSFSCAN_ISSUES" -gt 100 ]; then
            echo "" >> "$REPORT_FILE"
            echo "*... and $(($MOBSFSCAN_ISSUES - 100)) more findings. See full JSON report for details.*" >> "$REPORT_FILE"
        fi
    else
        # Array format
        cat >> "$REPORT_FILE" << 'TABLEHEAD'
| # | ID | Severity | File | Line | Description |
|---|----|---------:|------|------|-------------|
TABLEHEAD

        jq -r "$JQ_MD"'to_entries | .[] | "| \(.key + 1) | \(.value.id // "N/A" | md) | \(.value.severity // "INFO" | md) | \(.value.file // "N/A" | md) | \(.value.line // 0 | md) | \(.value.description // "" | .[0:50] | md)"' "$MOBSFSCAN_JSON" 2>/dev/null | head -50 >> "$REPORT_FILE"

        if [ "$MOBSFSCAN_ISSUES" -gt 50 ]; then
            echo "" >> "$REPORT_FILE"
            echo "*... and $(($MOBSFSCAN_ISSUES - 50)) more findings. See full JSON report for details.*" >> "$REPORT_FILE"
        fi
    fi

else
    cat >> "$REPORT_FILE" << EOF
**Status:** $MOBSFSCAN_STATUS
**Issues Found:** 0

✅ No mobile security issues detected.

EOF
fi

echo "---" >> "$REPORT_FILE"

# =============================================================================
# FINALIZE REPORT
# =============================================================================

cat >> "$REPORT_FILE" << 'EOF'

---

## 📝 Notes

- **Gitleaks**: Scans entire codebase for hardcoded secrets, API keys, and credentials
- **mobsfscan**: Mobile-specific security patterns (Android manifest, iOS plist, Flutter)

## 🔧 Configuration Files

| Tool | Config Location |
|------|---------------|
| Gitleaks | `.mobhook/<hook>.d/security/gitleaks.toml` |
| mobsfscan | `.mobhook/<hook>.d/security/.mobsf` |
---

*Generated by mobhook Security Hook*
EOF

# =============================================================================
# FINAL OUTPUT
# =============================================================================

secure_reports

echo ""
echo -e "${CYAN}═════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}📄 Reports Generated:${NC}"
echo -e "${CYAN}   ├── .hook-reports/gitleaks-report.json${NC}"
echo -e "${CYAN}   ├── .hook-reports/mobsfscan-report.json${NC}"
echo -e "${CYAN}   └── security-scan-report.md${NC}"
echo -e "${CYAN}═════════════════════════════════════════════════════════════${NC}"
echo ""

if [ $TOTAL_FAILURES -eq 0 ]; then
    echo -e "${GREEN}═════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ Security checks passed!${NC}"
    echo -e "${GREEN}═════════════════════════════════════════════════════════════${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}═════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}❌ $TOTAL_FAILURES security check(s) failed${NC}"
    echo -e "${RED}📄 Review the report: .hook-reports/security-scan-report.md${NC}"
    echo -e "${RED}═════════════════════════════════════════════════════════════${NC}"
    echo ""
    exit 1
fi
