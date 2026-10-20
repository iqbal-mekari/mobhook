#!/bin/bash
# =============================================================================
# Mobile Quality Report Script
# =============================================================================
# Local, static, latest-state code quality summary shaped like the SonarQube
# "Overall Code" tiles: Security, Reliability, Maintainability, Accepted issues,
# Coverage, Duplications, Security Hotspots.
#
# This is a lightweight local approximation, NOT numeric parity with SonarQube.
# No server, no container, no historical data. Everything runs locally.
#
# ORDER MATTERS: Security and Security Hotspots are read from the reports written
# by the `security` preset (.hook-reports/gitleaks-report.json and
# mobsfscan-report.json). List `security` BEFORE `quality-report` in the hook order.
#
# Default behaviour is report-only (exit 0). See thresholds.conf for the optional gate.
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory — thresholds.conf and baseline.txt live alongside this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use git to find the actual project root
PROJECT_ROOT="$(git rev-parse --show-toplevel)"

REPORT_DIR="$PROJECT_ROOT/.hook-reports"
REPORT_FILE="$REPORT_DIR/quality-report.md"
GITLEAKS_JSON="$REPORT_DIR/gitleaks-report.json"
MOBSFSCAN_JSON="$REPORT_DIR/mobsfscan-report.json"
SECURITY_REPORT="$REPORT_DIR/security-scan-report.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p "$REPORT_DIR"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Normalized issue model, one finding per line (tab separated):
#   category  severity  tool  rule  file
# category: bug | smell | vuln | hotspot      severity: low | medium | high | blocker
ISSUES_TSV="$WORK_DIR/issues.tsv"
: > "$ISSUES_TSV"

# Defaults, overridable in thresholds.conf
DEBT_RATIO_BANDS="5 10 20 50"
DEBT_MIN_LOW=5
DEBT_MIN_MEDIUM=15
DEBT_MIN_HIGH=30
DEV_COST_PER_LINE_MIN=30
HOTSPOT_REVIEW_BANDS="80 70 50 30"
DUPLICATION_MIN_LINES=5
DUPLICATION_MIN_TOKENS=50
FAIL_ON_RATING_WORSE_THAN=""
FAIL_ON_COVERAGE_BELOW=0
FAIL_ON_DUPLICATION_ABOVE=""

if [ -f "$SCRIPT_DIR/thresholds.conf" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/thresholds.conf"
fi

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Checks if a tool is installed; if not, interactively prompts to install it.
# An empty install_cmd means "cannot be auto-installed, show the hint only".
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

    if [ -z "$install_cmd" ]; then
        echo -e "${YELLOW}     Install manually: $install_label${NC}"
        return 1
    fi

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
                echo -e "${YELLOW}     Skipping — $tool checks will be skipped${NC}"
                return 1
                ;;
        esac
    else
        echo -e "${YELLOW}     Non-interactive session — install manually: $install_label${NC}"
        return 1
    fi
}

# List source files of the given extensions under a project subdirectory,
# excluding build output, vendored code and generated Dart files.
list_sources() {
    local dir="$1"
    shift
    local name_args=()
    local ext
    for ext in "$@"; do
        [ ${#name_args[@]} -gt 0 ] && name_args+=(-o)
        name_args+=(-name "*.$ext")
    done
    [ -d "$PROJECT_ROOT/$dir" ] || return 0
    find "$PROJECT_ROOT/$dir" -type f \( "${name_args[@]}" \) \
        -not -path '*/build/*' -not -path '*/Pods/*' -not -path '*/.dart_tool/*' \
        -not -path '*/.gradle/*' -not -path '*/DerivedData/*' \
        -not -name '*.g.dart' -not -name '*.freezed.dart' 2>/dev/null
}

count_loc() {
    local dir="$1"
    shift
    list_sources "$dir" "$@" | tr '\n' '\0' | xargs -0 cat 2>/dev/null | grep -c . || true
}

has_sources() {
    [ -n "$(list_sources "$1" "${@:2}" | head -n 1)" ]
}

# Rating helpers -------------------------------------------------------------

sev_to_rating() {
    case "$1" in
        low) echo "B" ;;
        medium) echo "C" ;;
        high) echo "D" ;;
        blocker) echo "E" ;;
        *) echo "A" ;;
    esac
}

rating_rank() {
    case "$1" in
        A) echo 1 ;; B) echo 2 ;; C) echo 3 ;; D) echo 4 ;; E) echo 5 ;; *) echo 0 ;;
    esac
}

# Worst open severity for a category, or "none"
worst_severity() {
    awk -F'\t' -v cat="$1" '
        BEGIN { rank["low"] = 1; rank["medium"] = 2; rank["high"] = 3; rank["blocker"] = 4 }
        $1 == cat && rank[$2] > worst { worst = rank[$2]; name = $2 }
        END { print (worst ? name : "none") }
    ' "$OPEN_TSV"
}

count_category() {
    awk -F'\t' -v cat="$1" '$1 == cat { n++ } END { print n + 0 }' "$2"
}

# Upper-bound bands (value <= band): A..D, otherwise E
rating_upper_bands() {
    awk -v v="$1" -v bands="$2" 'BEGIN {
        split(bands, b, " ")
        if (v <= b[1]) print "A"
        else if (v <= b[2]) print "B"
        else if (v <= b[3]) print "C"
        else if (v <= b[4]) print "D"
        else print "E"
    }'
}

# Lower-bound bands (value >= band): A..D, otherwise E
rating_lower_bands() {
    awk -v v="$1" -v bands="$2" 'BEGIN {
        split(bands, b, " ")
        if (v >= b[1]) print "A"
        else if (v >= b[2]) print "B"
        else if (v >= b[3]) print "C"
        else if (v >= b[4]) print "D"
        else print "E"
    }'
}

# Appends findings (already normalized, tab separated) to the issue model
add_issues_from() {
    cat >> "$ISSUES_TSV"
}

# =============================================================================
# TOOL CHECK
# =============================================================================

echo -e "${BLUE}🔍 Checking required tools...${NC}"

HAS_FLUTTER_PROJECT=false
[ -f "$PROJECT_ROOT/pubspec.yaml" ] && HAS_FLUTTER_PROJECT=true

HAS_KOTLIN_JAVA=false
has_sources android kt java && HAS_KOTLIN_JAVA=true
HAS_SWIFT=false
has_sources ios swift && HAS_SWIFT=true

JQ_AVAILABLE=true
DART_AVAILABLE=false
FLUTTER_AVAILABLE=false
JSCPD_AVAILABLE=false
DETEKT_AVAILABLE=false
SWIFTLINT_AVAILABLE=false

check_and_install_tool "jq" "brew install jq" "brew install jq" || JQ_AVAILABLE=false

if $HAS_FLUTTER_PROJECT; then
    check_and_install_tool "dart" "" "https://docs.flutter.dev/get-started/install (dart ships with the Flutter SDK)" \
        && DART_AVAILABLE=true
    check_and_install_tool "flutter" "" "https://docs.flutter.dev/get-started/install" \
        && FLUTTER_AVAILABLE=true
fi
if $HAS_KOTLIN_JAVA; then
    check_and_install_tool "detekt" "brew install detekt" "brew install detekt" \
        && DETEKT_AVAILABLE=true
fi
if $HAS_SWIFT; then
    if [ "$(uname)" = "Darwin" ]; then
        check_and_install_tool "swiftlint" "brew install swiftlint" "brew install swiftlint" \
            && SWIFTLINT_AVAILABLE=true
    else
        echo -e "${YELLOW}  ⚠️  swiftlint skipped (iOS sources found, but not running on macOS)${NC}"
    fi
fi
check_and_install_tool "jscpd" "npm install -g jscpd" "npm install -g jscpd" \
    && JSCPD_AVAILABLE=true

echo ""
echo -e "${BLUE}📊 mobhook Quality Report${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════${NC}"
echo ""

SOURCES_USED=()
SOURCES_SKIPPED=()

# =============================================================================
# SECURITY + HOTSPOTS: read the security preset output (no rescan)
# =============================================================================

echo -e "${BLUE}[1/5] Reading security preset reports...${NC}"

SECURITY_AVAILABLE=false
security_tool_skipped() {
    # The security preset seeds an empty JSON even when a tool was skipped,
    # so consult its summary table to tell "clean" from "not run".
    [ -f "$SECURITY_REPORT" ] && grep -Eq "^\| $1 \| .*Skipped" "$SECURITY_REPORT"
}

if $JQ_AVAILABLE; then
    if [ -s "$GITLEAKS_JSON" ] && ! security_tool_skipped "Gitleaks"; then
        # Only rule id and file are read: the secret value itself is never extracted.
        jq -r '.[]? | ["vuln", "high", "gitleaks", (.RuleID // "unknown"), (.File // "")] | @tsv' \
            "$GITLEAKS_JSON" 2>/dev/null \
            | awk -F'\t' -v OFS='\t' -v root="$PROJECT_ROOT/" '
                { if (index($5, root) == 1) $5 = substr($5, length(root) + 1); print }' \
            | add_issues_from
        SOURCES_USED+=("gitleaks (from security preset)")
        SECURITY_AVAILABLE=true
    else
        SOURCES_SKIPPED+=("gitleaks: no report from the security preset")
    fi

    if [ -s "$MOBSFSCAN_JSON" ] && ! security_tool_skipped "mobsfscan"; then
        jq -r '
            if type == "object" and has("results") then
                .results | to_entries[]
                | .key as $rule
                | (.value.metadata.severity // "INFO") as $sev
                | (.value.files // [])[]
                | [$rule, $sev, (.file_path // "")]
            else
                (.[]? | [(.id // "unknown"), (.severity // "INFO"), (.file // "")])
            end | @tsv' "$MOBSFSCAN_JSON" 2>/dev/null \
            | awk -F'\t' -v OFS='\t' -v root="$PROJECT_ROOT/" '
                {
                    sev = toupper($2)
                    file = $3
                    if (index(file, root) == 1) file = substr(file, length(root) + 1)
                    # ERROR -> vulnerability; WARNING/INFO -> hotspot needing review
                    if (sev == "ERROR") print "vuln", "high", "mobsfscan", $1, file
                    else if (sev == "WARNING") print "hotspot", "medium", "mobsfscan", $1, file
                    else print "hotspot", "low", "mobsfscan", $1, file
                }' \
            | add_issues_from
        SOURCES_USED+=("mobsfscan (from security preset)")
        SECURITY_AVAILABLE=true
    else
        SOURCES_SKIPPED+=("mobsfscan: no report from the security preset")
    fi
else
    SOURCES_SKIPPED+=("security reports: jq is required to parse them")
fi

if ! $SECURITY_AVAILABLE; then
    echo -e "${YELLOW}  ⚠️  Security data not available — run the security preset before quality-report${NC}"
fi

# =============================================================================
# RELIABILITY + MAINTAINABILITY: dart analyze / detekt / swiftlint
# =============================================================================

echo -e "${BLUE}[2/5] Running static analysis...${NC}"

ANALYSIS_AVAILABLE=false

# dart analyze: ERROR -> bug/high; selected bug-prone rules -> bug/medium;
# other WARNING -> smell/medium; INFO (hints and lints) -> smell/low
if $HAS_FLUTTER_PROJECT && $DART_AVAILABLE; then
    ( cd "$PROJECT_ROOT" && dart analyze --format=machine 2>&1 ) \
        | grep -E '^(ERROR|WARNING|INFO)\|' | sort -u \
        | awk -F'|' -v OFS='\t' -v root="$PROJECT_ROOT/" '
            BEGIN {
                n = split("dead_code unrelated_type_equality_checks invalid_use_of_protected_member " \
                          "invalid_use_of_visible_for_testing_member null_check_always_fails " \
                          "invalid_null_aware_operator unnecessary_null_comparison " \
                          "body_might_complete_normally use_build_context_synchronously " \
                          "close_sinks cancel_subscriptions", list, " ")
                for (i = 1; i <= n; i++) buggy[list[i]] = 1
            }
            {
                sev = $1; rule = tolower($3); file = $4
                if (index(file, root) == 1) file = substr(file, length(root) + 1)
                if (file ~ /(^|\/)(build|\.dart_tool)\// || file ~ /\.(g|freezed)\.dart$/) next
                if (sev == "ERROR") print "bug", "high", "dart-analyze", rule, file
                else if (rule in buggy) print "bug", "medium", "dart-analyze", rule, file
                else if (sev == "WARNING") print "smell", "medium", "dart-analyze", rule, file
                else print "smell", "low", "dart-analyze", rule, file
            }' \
        | add_issues_from
    SOURCES_USED+=("dart analyze")
    ANALYSIS_AVAILABLE=true
elif $HAS_FLUTTER_PROJECT; then
    SOURCES_SKIPPED+=("dart analyze: dart not found")
fi

# detekt (Kotlin): potential-bugs rule set -> bug; everything else -> smell.
# SARIF level: error -> high, warning -> medium, note -> low.
if $HAS_KOTLIN_JAVA && $DETEKT_AVAILABLE && $JQ_AVAILABLE; then
    DETEKT_SARIF="$WORK_DIR/detekt.sarif"
    ( cd "$PROJECT_ROOT" && detekt --input android --report "sarif:$DETEKT_SARIF" \
        --excludes '**/build/**,**/.gradle/**' --build-upon-default-config >/dev/null 2>&1 )
    if [ -s "$DETEKT_SARIF" ]; then
        jq -r '.runs[]?.results[]? | [(.ruleId // "unknown"), (.level // "warning"),
                (.locations[0].physicalLocation.artifactLocation.uri // "")] | @tsv' \
            "$DETEKT_SARIF" 2>/dev/null \
            | awk -F'\t' -v OFS='\t' -v root="$PROJECT_ROOT/" '
                {
                    file = $3
                    sub(/^file:\/\//, "", file)
                    if (index(file, root) == 1) file = substr(file, length(root) + 1)
                    if (file ~ /(^|\/)(build|\.gradle)\//) next
                    cat = ($1 ~ /potential-bugs/) ? "bug" : "smell"
                    sev = ($2 == "error") ? "high" : (($2 == "note") ? "low" : "medium")
                    print cat, sev, "detekt", $1, file
                }' \
            | add_issues_from
        SOURCES_USED+=("detekt")
        ANALYSIS_AVAILABLE=true
    else
        SOURCES_SKIPPED+=("detekt: produced no report")
    fi
elif $HAS_KOTLIN_JAVA; then
    SOURCES_SKIPPED+=("detekt: not installed (android code not analyzed)")
fi

# swiftlint (iOS): every finding is a smell. Error -> high, Warning -> medium.
if $HAS_SWIFT && $SWIFTLINT_AVAILABLE && $JQ_AVAILABLE; then
    ( cd "$PROJECT_ROOT/ios" && swiftlint lint --quiet --reporter json 2>/dev/null ) \
        | jq -r '.[]? | [(.rule_id // "unknown"), (.severity // "Warning"), (.file // "")] | @tsv' 2>/dev/null \
        | awk -F'\t' -v OFS='\t' -v root="$PROJECT_ROOT/" '
            {
                file = $3
                if (index(file, root) == 1) file = substr(file, length(root) + 1)
                if (file ~ /(^|\/)(Pods|build|DerivedData)\//) next
                print "smell", (tolower($2) == "error" ? "high" : "medium"), "swiftlint", $1, file
            }' \
        | add_issues_from
    SOURCES_USED+=("swiftlint")
    ANALYSIS_AVAILABLE=true
elif $HAS_SWIFT; then
    SOURCES_SKIPPED+=("swiftlint: not available (iOS code not analyzed)")
fi

# Lines of code, the denominator of the technical debt ratio
LOC=0
$HAS_FLUTTER_PROJECT && LOC=$((LOC + $(count_loc lib dart)))
$HAS_KOTLIN_JAVA && LOC=$((LOC + $(count_loc android kt java)))
$HAS_SWIFT && LOC=$((LOC + $(count_loc ios swift)))

# =============================================================================
# BASELINE: accepted issues
# =============================================================================

echo -e "${BLUE}[3/5] Applying baseline (accepted issues)...${NC}"

OPEN_TSV="$WORK_DIR/open.tsv"
ACCEPTED_TSV="$WORK_DIR/accepted.tsv"
BASELINE_PATTERNS="$WORK_DIR/baseline.patterns"

if [ -f "$SCRIPT_DIR/baseline.txt" ]; then
    grep -Ev '^[[:space:]]*(#|$)' "$SCRIPT_DIR/baseline.txt" | tr -d '\r' > "$BASELINE_PATTERNS"
else
    : > "$BASELINE_PATTERNS"
fi

if [ -s "$BASELINE_PATTERNS" ]; then
    awk -F'\t' -v OFS='\t' -v open="$OPEN_TSV" -v accepted="$ACCEPTED_TSV" '
        function glob_to_regex(g,    i, c, out) {
            out = ""
            for (i = 1; i <= length(g); i++) {
                c = substr(g, i, 1)
                if (c == "*") out = out ".*"
                else if (index(".+?^$(){}|[]\\", c)) out = out "\\" c
                else out = out c
            }
            return "^" out "$"
        }
        NR == FNR { gsub(/^[ \t]+|[ \t]+$/, "", $0); re[++n] = glob_to_regex($0); next }
        {
            fp = $3 "|" $4 "|" $5
            hit = 0
            for (i = 1; i <= n; i++) if (fp ~ re[i]) { hit = 1; break }
            print $0 > (hit ? accepted : open)
        }' "$BASELINE_PATTERNS" "$ISSUES_TSV"
    [ -f "$OPEN_TSV" ] || : > "$OPEN_TSV"
    [ -f "$ACCEPTED_TSV" ] || : > "$ACCEPTED_TSV"
else
    cp "$ISSUES_TSV" "$OPEN_TSV"
    : > "$ACCEPTED_TSV"
fi

ACCEPTED_COUNT=$(wc -l < "$ACCEPTED_TSV" | tr -d ' ')

# =============================================================================
# COVERAGE
# =============================================================================

echo -e "${BLUE}[4/5] Measuring coverage...${NC}"

COVERAGE_AVAILABLE=false
COVERAGE_PCT=""
COVERAGE_LINES=0
COVERAGE_NOTE=""
LCOV_FILE="$PROJECT_ROOT/coverage/lcov.info"

if $HAS_FLUTTER_PROJECT && $FLUTTER_AVAILABLE; then
    if [ "${QUALITY_REPORT_REUSE_COVERAGE:-0}" != "1" ]; then
        if [ -d "$PROJECT_ROOT/test" ]; then
            ( cd "$PROJECT_ROOT" && flutter test --coverage >"$WORK_DIR/flutter-test.log" 2>&1 )
            if [ $? -ne 0 ]; then
                COVERAGE_NOTE="some tests failed; coverage may be partial"
                echo -e "${YELLOW}  ⚠️  flutter test reported failures${NC}"
            fi
        else
            COVERAGE_NOTE="no test/ directory"
        fi
    fi
    if [ -s "$LCOV_FILE" ]; then
        read -r COVERAGE_HIT COVERAGE_LINES < <(awk -F: '
            /^SF:/ { skip = ($2 ~ /\.(g|freezed)\.dart$/) }
            !skip && /^LF:/ { lf += $2 }
            !skip && /^LH:/ { lh += $2 }
            END { print lh + 0, lf + 0 }' "$LCOV_FILE")
        if [ "$COVERAGE_LINES" -gt 0 ]; then
            COVERAGE_PCT=$(awk -v h="$COVERAGE_HIT" -v l="$COVERAGE_LINES" 'BEGIN { printf "%.1f", h * 100 / l }')
            COVERAGE_AVAILABLE=true
            SOURCES_USED+=("flutter test --coverage")
        fi
    fi
    $COVERAGE_AVAILABLE || SOURCES_SKIPPED+=("coverage: no lcov data produced")
elif $HAS_FLUTTER_PROJECT; then
    SOURCES_SKIPPED+=("coverage: flutter not found")
else
    SOURCES_SKIPPED+=("coverage: not a Flutter project (no pubspec.yaml)")
fi

# =============================================================================
# DUPLICATIONS
# =============================================================================

echo -e "${BLUE}[5/5] Detecting duplications...${NC}"

DUPLICATION_AVAILABLE=false
DUPLICATION_PCT=""
DUPLICATION_LINES=0

if $JSCPD_AVAILABLE && $JQ_AVAILABLE; then
    DUP_DIRS=()
    for d in lib android ios; do
        [ -d "$PROJECT_ROOT/$d" ] && DUP_DIRS+=("$d")
    done
    if [ ${#DUP_DIRS[@]} -gt 0 ]; then
        ( cd "$PROJECT_ROOT" && jscpd "${DUP_DIRS[@]}" \
            --reporters json --output "$WORK_DIR/jscpd" --silent \
            --format "dart,kotlin,java,swift" \
            --min-lines "$DUPLICATION_MIN_LINES" --min-tokens "$DUPLICATION_MIN_TOKENS" \
            --ignore "**/*.g.dart,**/*.freezed.dart,**/build/**,**/Pods/**,**/.dart_tool/**,**/.gradle/**" \
            >/dev/null 2>&1 )
        JSCPD_JSON="$WORK_DIR/jscpd/jscpd-report.json"
        if [ -s "$JSCPD_JSON" ]; then
            DUPLICATION_LINES=$(jq -r '.statistics.total.lines // 0' "$JSCPD_JSON" 2>/dev/null)
            DUPLICATION_PCT=$(jq -r '.statistics.total.percentage // empty' "$JSCPD_JSON" 2>/dev/null)
            if [ -n "$DUPLICATION_PCT" ]; then
                DUPLICATION_PCT=$(awk -v p="$DUPLICATION_PCT" 'BEGIN { printf "%.1f", p }')
                DUPLICATION_AVAILABLE=true
                SOURCES_USED+=("jscpd")
            fi
        fi
    fi
    $DUPLICATION_AVAILABLE || SOURCES_SKIPPED+=("duplications: jscpd produced no report")
else
    SOURCES_SKIPPED+=("duplications: jscpd (and jq) required")
fi

echo ""

# =============================================================================
# COMPUTE TILES
# =============================================================================

NA="not available"

# Security: open vulnerabilities, rating from worst severity
if $SECURITY_AVAILABLE; then
    SEC_COUNT=$(count_category vuln "$OPEN_TSV")
    SEC_RATING=$(sev_to_rating "$(worst_severity vuln)")
    SEC_VALUE="$SEC_COUNT open issues"
else
    SEC_COUNT=""; SEC_RATING=""; SEC_VALUE="$NA"
fi

# Reliability: open bugs, rating from worst severity
if $ANALYSIS_AVAILABLE; then
    REL_COUNT=$(count_category bug "$OPEN_TSV")
    REL_RATING=$(sev_to_rating "$(worst_severity bug)")
    REL_VALUE="$REL_COUNT open issues"
else
    REL_COUNT=""; REL_RATING=""; REL_VALUE="$NA"
fi

# Maintainability: open smells, rating from technical debt ratio
if $ANALYSIS_AVAILABLE; then
    MAINT_COUNT=$(count_category smell "$OPEN_TSV")
    DEBT_MIN=$(awk -F'\t' -v lo="$DEBT_MIN_LOW" -v me="$DEBT_MIN_MEDIUM" -v hi="$DEBT_MIN_HIGH" '
        $1 == "smell" { m += ($2 == "low") ? lo : (($2 == "medium") ? me : hi) }
        END { print m + 0 }' "$OPEN_TSV")
    if [ "$LOC" -gt 0 ]; then
        DEBT_RATIO=$(awk -v d="$DEBT_MIN" -v l="$LOC" -v c="$DEV_COST_PER_LINE_MIN" 'BEGIN { printf "%.1f", d * 100 / (l * c) }')
    else
        DEBT_RATIO="0.0"
    fi
    MAINT_RATING=$(rating_upper_bands "$DEBT_RATIO" "$DEBT_RATIO_BANDS")
    MAINT_VALUE="$MAINT_COUNT open issues (debt ratio ${DEBT_RATIO}%)"
else
    MAINT_COUNT=""; MAINT_RATING=""; MAINT_VALUE="$NA"; DEBT_RATIO=""
fi

# Security hotspots: open count, rating from share of hotspots reviewed (baselined)
if $SECURITY_AVAILABLE; then
    HOT_OPEN=$(count_category hotspot "$OPEN_TSV")
    HOT_REVIEWED=$(count_category hotspot "$ACCEPTED_TSV")
    HOT_TOTAL=$((HOT_OPEN + HOT_REVIEWED))
    if [ "$HOT_TOTAL" -eq 0 ]; then
        HOT_REVIEW_PCT=100
    else
        HOT_REVIEW_PCT=$(awk -v r="$HOT_REVIEWED" -v t="$HOT_TOTAL" 'BEGIN { printf "%.1f", r * 100 / t }')
    fi
    HOT_RATING=$(rating_lower_bands "$HOT_REVIEW_PCT" "$HOTSPOT_REVIEW_BANDS")
    HOT_VALUE="$HOT_OPEN to review (${HOT_REVIEW_PCT}% reviewed)"
else
    HOT_RATING=""; HOT_VALUE="$NA"
fi

if $COVERAGE_AVAILABLE; then
    COV_VALUE="${COVERAGE_PCT}% on ${COVERAGE_LINES} lines to cover"
else
    COV_VALUE="$NA"
fi

if $DUPLICATION_AVAILABLE; then
    DUP_VALUE="${DUPLICATION_PCT}% on ${DUPLICATION_LINES} lines"
else
    DUP_VALUE="$NA"
fi

with_rating() {
    if [ -n "$2" ]; then echo "$1 — **$2**"; else echo "$1"; fi
}

# =============================================================================
# WRITE MARKDOWN REPORT
# =============================================================================

{
    cat << EOF
# Code Quality Report

**Generated:** $TIMESTAMP
**Project:** $(basename "$PROJECT_ROOT")
**Branch:** $(git branch --show-current 2>/dev/null || echo "unknown")
**Commit:** $(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

> Local approximation of SonarQube "Overall Code". Latest state only, no history,
> not numerically equivalent to SonarQube.

---

## 📊 Overall Code

| Tile | Result |
|------|--------|
| Security | $(with_rating "$SEC_VALUE" "$SEC_RATING") |
| Reliability | $(with_rating "$REL_VALUE" "$REL_RATING") |
| Maintainability | $(with_rating "$MAINT_VALUE" "$MAINT_RATING") |
| Accepted issues | $ACCEPTED_COUNT |
| Coverage | $COV_VALUE |
| Duplications | $DUP_VALUE |
| Security Hotspots | $(with_rating "$HOT_VALUE" "$HOT_RATING") |

---

## 🧰 Sources

EOF
    if [ ${#SOURCES_USED[@]} -gt 0 ]; then
        for s in "${SOURCES_USED[@]}"; do echo "- ✅ $s"; done
    else
        echo "- (no analysis source ran)"
    fi
    if [ ${#SOURCES_SKIPPED[@]} -gt 0 ]; then
        for s in "${SOURCES_SKIPPED[@]}"; do echo "- ⚠️ $s"; done
    fi
    [ -n "$COVERAGE_NOTE" ] && echo "- ℹ️ coverage: $COVERAGE_NOTE"

    cat << EOF

---

## 🔎 Open Issues by Source

| Tool | Bugs | Smells | Vulnerabilities | Hotspots |
|------|------|--------|-----------------|----------|
EOF
    awk -F'\t' '
        { t[$3] = 1; c[$3, $1]++ }
        END { for (k in t) printf "| %s | %d | %d | %d | %d |\n", k, c[k,"bug"], c[k,"smell"], c[k,"vuln"], c[k,"hotspot"] }
    ' "$OPEN_TSV" | sort
    cat << EOF

---

*Generated by mobhook quality-report. Bands: \`thresholds.conf\`. Accepted issues: \`baseline.txt\`.*
EOF
} > "$REPORT_FILE"

# =============================================================================
# TERMINAL SUMMARY
# =============================================================================

print_tile() {
    printf "  %-18s %s\n" "$1" "$2"
}

echo -e "${CYAN}═════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}📊 Overall Code${NC}"
print_tile "Security" "$(with_rating "$SEC_VALUE" "$SEC_RATING" | tr -d '*')"
print_tile "Reliability" "$(with_rating "$REL_VALUE" "$REL_RATING" | tr -d '*')"
print_tile "Maintainability" "$(with_rating "$MAINT_VALUE" "$MAINT_RATING" | tr -d '*')"
print_tile "Accepted issues" "$ACCEPTED_COUNT"
print_tile "Coverage" "$COV_VALUE"
print_tile "Duplications" "$DUP_VALUE"
print_tile "Security Hotspots" "$(with_rating "$HOT_VALUE" "$HOT_RATING" | tr -d '*')"
echo -e "${CYAN}═════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}📄 Full report: .hook-reports/quality-report.md${NC}"
echo ""

# =============================================================================
# OPTIONAL THRESHOLD GATE (default: report only)
# =============================================================================

GATE_FAILURES=0

if [ -n "$FAIL_ON_RATING_WORSE_THAN" ]; then
    LIMIT_RANK=$(rating_rank "$FAIL_ON_RATING_WORSE_THAN")
    for pair in "Security:$SEC_RATING" "Reliability:$REL_RATING" "Maintainability:$MAINT_RATING"; do
        name="${pair%%:*}"; rating="${pair#*:}"
        [ -z "$rating" ] && continue
        if [ "$(rating_rank "$rating")" -gt "$LIMIT_RANK" ]; then
            echo -e "${RED}❌ $name rating $rating is worse than $FAIL_ON_RATING_WORSE_THAN${NC}"
            GATE_FAILURES=$((GATE_FAILURES + 1))
        fi
    done
fi

if [ "$FAIL_ON_COVERAGE_BELOW" != "0" ] && $COVERAGE_AVAILABLE; then
    if awk -v c="$COVERAGE_PCT" -v m="$FAIL_ON_COVERAGE_BELOW" 'BEGIN { exit !(c < m) }'; then
        echo -e "${RED}❌ Coverage ${COVERAGE_PCT}% is below ${FAIL_ON_COVERAGE_BELOW}%${NC}"
        GATE_FAILURES=$((GATE_FAILURES + 1))
    fi
fi

if [ -n "$FAIL_ON_DUPLICATION_ABOVE" ] && $DUPLICATION_AVAILABLE; then
    if awk -v d="$DUPLICATION_PCT" -v m="$FAIL_ON_DUPLICATION_ABOVE" 'BEGIN { exit !(d > m) }'; then
        echo -e "${RED}❌ Duplications ${DUPLICATION_PCT}% exceed ${FAIL_ON_DUPLICATION_ABOVE}%${NC}"
        GATE_FAILURES=$((GATE_FAILURES + 1))
    fi
fi

if [ $GATE_FAILURES -eq 0 ]; then
    echo -e "${GREEN}✅ Quality report generated${NC}"
    exit 0
else
    echo -e "${RED}❌ $GATE_FAILURES quality threshold(s) breached (see thresholds.conf)${NC}"
    exit 1
fi
