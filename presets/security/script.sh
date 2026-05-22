#!/bin/bash
# =============================================================================
# Mobile Security Scan Script
# =============================================================================
# Runs gitleaks and mobsfscan security scans
# Designed to run as part of the hook dispatcher (via .d/ directory)
#
# Privacy Guarantee: All scanning happens locally. No data leaves your machine.
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory — config files (gitleaks.toml, .mobsf) live alongside this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use git to find the actual project root
PROJECT_ROOT="$(git rev-parse --show-toplevel)"

# =============================================================================
# REPORT SETUP
# =============================================================================

REPORT_DIR="$PROJECT_ROOT/.hook-reports"
REPORT_FILE="$REPORT_DIR/security-scan-report.md"
GITLEAKS_JSON="$REPORT_DIR/gitleaks-report.json"
MOBSFSCAN_JSON="$REPORT_DIR/mobsfscan-report.json"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
TOTAL_FAILURES=0

# Create reports directory
mkdir -p "$REPORT_DIR"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Escape markdown special characters
escape_md() {
    echo "$1" | sed 's/`/\\`/g' | sed 's/```/\\`\\`\\`/g'
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
# Returns 0 if the tool is available (already present or just installed), 1 otherwise.
check_and_install_tool() {
    local tool="$1"
    local install_cmd="$2"
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
                eval "$install_cmd"
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

check_and_install_tool "gitleaks" "brew install gitleaks" "brew install gitleaks" \
    || GITLEAKS_AVAILABLE=false
check_and_install_tool "mobsfscan" "pip3 install mobsfscan" "pip install mobsfscan" \
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

# Initialize empty JSON array
echo "[]" > "$GITLEAKS_JSON"

if $GITLEAKS_AVAILABLE; then
    set +e
    if [ -f "$SCRIPT_DIR/gitleaks.toml" ]; then
        gitleaks detect --source "$PROJECT_ROOT" --config "$SCRIPT_DIR/gitleaks.toml" --no-git --report-path "$GITLEAKS_JSON" --report-format json 2>&1 | tee /tmp/gitleaks-stdout.txt
    else
        gitleaks detect --source "$PROJECT_ROOT" --no-git --report-path "$GITLEAKS_JSON" --report-format json 2>&1 | tee /tmp/gitleaks-stdout.txt
    fi
    GITLEAKS_EXIT_CODE=$?
    set -e

    # Count issues from JSON
    if [ -s "$GITLEAKS_JSON" ]; then
        GITLEAKS_ISSUES=$(jq 'length' "$GITLEAKS_JSON" 2>/dev/null || echo "0")
    fi

    if [ $GITLEAKS_EXIT_CODE -ne 0 ] && [ "$GITLEAKS_ISSUES" != "0" ]; then
        echo -e "${RED}❌ Gitleaks: $GITLEAKS_ISSUES secret(s) detected!${NC}"
        GITLEAKS_STATUS="❌ Fail"
        ((TOTAL_FAILURES++))
    elif [ "$GITLEAKS_ISSUES" != "0" ]; then
        echo -e "${YELLOW}⚠️  Gitleaks: $GITLEAKS_ISSUES warning(s)${NC}"
        GITLEAKS_STATUS="⚠️ Warnings"
    else
        echo -e "${GREEN}✅ Gitleaks: No secrets found${NC}"
    fi

    rm -f /tmp/gitleaks-stdout.txt
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

# Initialize empty JSON
echo '{"findings": []}' > "$MOBSFSCAN_JSON"

if $MOBSFSCAN_AVAILABLE; then
    set +e
    # Run mobsfscan - warnings go to stderr, JSON to stdout
    if [ -f "$SCRIPT_DIR/.mobsf" ]; then
        mobsfscan "$PROJECT_ROOT" --config "$SCRIPT_DIR/.mobsf" --json > "$MOBSFSCAN_JSON" 2>/tmp/mobsfscan-warnings.txt
    else
        mobsfscan "$PROJECT_ROOT" --json > "$MOBSFSCAN_JSON" 2>/tmp/mobsfscan-warnings.txt
    fi
    MOBSFSCAN_EXIT_CODE=$?
    set -e

    # Display warnings if any
    if [ -s /tmp/mobsfscan-warnings.txt ]; then
        cat /tmp/mobsfscan-warnings.txt | head -10
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

    rm -f /tmp/mobsfscan-warnings.txt

    if [ $MOBSFSCAN_EXIT_CODE -ne 0 ] && [ "$MOBSFSCAN_ISSUES" != "0" ]; then
        echo -e "${RED}❌ mobsfscan: $MOBSFSCAN_ISSUES issue(s) detected!${NC}"
        MOBSFSCAN_STATUS="❌ Fail"
        ((TOTAL_FAILURES++))
    elif [ "$MOBSFSCAN_ISSUES" != "0" ]; then
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
elif [ -s "$GITLEAKS_JSON" ] && [ "$(jq 'length' "$GITLEAKS_JSON" 2>/dev/null)" != "0" ]; then
    cat >> "$REPORT_FILE" << EOF
**Status:** $GITLEAKS_STATUS
**Issues Found:** $GITLEAKS_ISSUES

### Findings

| # | Rule | Severity | File | Line | Match |
|---|------|----------|------|------|-------|
EOF

    jq -r 'to_entries | .[] | "| \(.key + 1) | \(.value.RuleID) | \(.value.severity // "N/A") | \(.value.File) | \(.value.StartLine) | \(.value.Match | .[0:50])"' "$GITLEAKS_JSON" 2>/dev/null | head -50 >> "$REPORT_FILE"

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
elif [ -s "$MOBSFSCAN_JSON" ] && [ "$(jq 'if type == "object" and has("results") then [.results | to_entries[] | select(.value.files != null) | .value.files | length] | add // 0 elif type == "array" then length else 0 end' "$MOBSFSCAN_JSON" 2>/dev/null)" != "0" ]; then
    cat >> "$REPORT_FILE" << EOF
**Status:** $MOBSFSCAN_STATUS
**Issues Found:** $MOBSFSCAN_ISSUES

### Findings

EOF

    # Handle new mobsfscan format with results object
    if jq -e 'type == "object" and has("results")' "$MOBSFSCAN_JSON" > /dev/null 2>&1; then
        cat >> "$REPORT_FILE" << 'TABLEHEAD'
| # | Rule ID | Severity | File | Line | Match |
|---|---------|----------|------|------|-------|
TABLEHEAD

        jq -r '.results | to_entries[] | select(.value.files != null) | .key as $rule | .value.metadata.severity as $sev | .value.files[]? | "| | \($rule) | \($sev // "INFO") | \(.file_path | split("/") | .[-1]) | \(.match_lines[0]) | \(.match_string | .[0:40] | gsub("\\n"; " "))"' "$MOBSFSCAN_JSON" 2>/dev/null | head -100 >> "$REPORT_FILE"

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

        jq -r 'to_entries | .[] | "| \(.key + 1) | \(.value.id // "N/A") | \(.value.severity // "INFO") | \(.value.file // "N/A") | \(.value.line // 0) | \(.value.description // "" | .[0:50])"' "$MOBSFSCAN_JSON" 2>/dev/null | head -50 >> "$REPORT_FILE"

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
