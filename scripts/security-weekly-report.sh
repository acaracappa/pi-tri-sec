#!/bin/bash
# Security Weekly Report Aggregator
# Consolidates reports from lynis, rkhunter, and AIDE

set -o pipefail

REPORT_DIR="/var/log/security"
WEEKLY_REPORT="${REPORT_DIR}/weekly-report.txt"
HOSTNAME=$(hostname)
TIMESTAMP=$(date -Iseconds)
OVERALL_STATUS="OK"

# Function to get summary value
get_value() {
    local file="$1"
    local key="$2"
    grep "^${key}:" "$file" 2>/dev/null | cut -d: -f2 | tr -d ' ' || echo "N/A"
}

# Function to get section content
get_section() {
    local file="$1"
    local section="$2"
    sed -n "/^--- ${section} ---/,/^---/p" "$file" 2>/dev/null | grep -v "^---" | head -10 || echo "N/A"
}

# Check each tool's summary
LYNIS_STATUS=$(get_value "${REPORT_DIR}/lynis/summary.txt" "STATUS")
RKHUNTER_STATUS=$(get_value "${REPORT_DIR}/rkhunter/summary.txt" "STATUS")
AIDE_STATUS=$(get_value "${REPORT_DIR}/aide/summary.txt" "STATUS")

LYNIS_SCORE=$(get_value "${REPORT_DIR}/lynis/summary.txt" "HARDENING_INDEX")
ROOTKITS_FOUND=$(get_value "${REPORT_DIR}/rkhunter/summary.txt" "ROOTKITS_FOUND")
FILES_CHANGED=$(get_value "${REPORT_DIR}/aide/summary.txt" "FILES_CHANGED")

# Determine overall status
for status in "$LYNIS_STATUS" "$RKHUNTER_STATUS" "$AIDE_STATUS"; do
    if [ "$status" = "CRITICAL" ]; then
        OVERALL_STATUS="CRITICAL"
        break
    elif [ "$status" = "WARNING" ] && [ "$OVERALL_STATUS" != "CRITICAL" ]; then
        OVERALL_STATUS="WARNING"
    fi
done

# Count tools that ran successfully
TOOLS_RAN=0
TOOLS_MISSING=""
[ -f "${REPORT_DIR}/lynis/summary.txt" ] && TOOLS_RAN=$((TOOLS_RAN + 1)) || TOOLS_MISSING="${TOOLS_MISSING} lynis"
[ -f "${REPORT_DIR}/rkhunter/summary.txt" ] && TOOLS_RAN=$((TOOLS_RAN + 1)) || TOOLS_MISSING="${TOOLS_MISSING} rkhunter"
[ -f "${REPORT_DIR}/aide/summary.txt" ] && TOOLS_RAN=$((TOOLS_RAN + 1)) || TOOLS_MISSING="${TOOLS_MISSING} aide"

# Generate report
cat > "${WEEKLY_REPORT}" << REPORT_EOF
================================================================================
                    WEEKLY SECURITY REPORT - ${HOSTNAME}
                    Generated: ${TIMESTAMP}
================================================================================

EXECUTIVE SUMMARY
-----------------
Overall Status: ${OVERALL_STATUS}
Tools Reporting: ${TOOLS_RAN}/3${TOOLS_MISSING:+ (missing:${TOOLS_MISSING})}

Lynis Hardening Score: ${LYNIS_SCORE:-N/A}/100
Rootkits Found: ${ROOTKITS_FOUND:-N/A}
File Integrity Changes: ${FILES_CHANGED:-N/A}

ATTENTION REQUIRED
------------------
REPORT_EOF

# Add attention items from each tool
{
    echo "=== Lynis ===" 
    if [ -f "${REPORT_DIR}/lynis/summary.txt" ]; then
        get_section "${REPORT_DIR}/lynis/summary.txt" "ATTENTION REQUIRED"
    else
        echo "No scan data available"
    fi
    echo ""
    
    echo "=== rkhunter ==="
    if [ -f "${REPORT_DIR}/rkhunter/summary.txt" ]; then
        get_section "${REPORT_DIR}/rkhunter/summary.txt" "ATTENTION REQUIRED"
    else
        echo "No scan data available"
    fi
    echo ""
    
    echo "=== AIDE ==="
    if [ -f "${REPORT_DIR}/aide/summary.txt" ]; then
        get_section "${REPORT_DIR}/aide/summary.txt" "ATTENTION REQUIRED"
    else
        echo "No scan data available"
    fi
} >> "${WEEKLY_REPORT}"

# Add detailed findings
cat >> "${WEEKLY_REPORT}" << REPORT_EOF

DETAILED FINDINGS
-----------------

--- LYNIS SECURITY AUDIT ---
REPORT_EOF

if [ -f "${REPORT_DIR}/lynis/summary.txt" ]; then
    cat "${REPORT_DIR}/lynis/summary.txt" >> "${WEEKLY_REPORT}"
else
    echo "Scan not available" >> "${WEEKLY_REPORT}"
fi

cat >> "${WEEKLY_REPORT}" << REPORT_EOF

--- RKHUNTER ROOTKIT SCAN ---
REPORT_EOF

if [ -f "${REPORT_DIR}/rkhunter/summary.txt" ]; then
    cat "${REPORT_DIR}/rkhunter/summary.txt" >> "${WEEKLY_REPORT}"
else
    echo "Scan not available" >> "${WEEKLY_REPORT}"
fi

cat >> "${WEEKLY_REPORT}" << REPORT_EOF

--- AIDE FILE INTEGRITY ---
REPORT_EOF

if [ -f "${REPORT_DIR}/aide/summary.txt" ]; then
    cat "${REPORT_DIR}/aide/summary.txt" >> "${WEEKLY_REPORT}"
else
    echo "Scan not available" >> "${WEEKLY_REPORT}"
fi

cat >> "${WEEKLY_REPORT}" << REPORT_EOF

================================================================================
                              END OF REPORT
================================================================================
REPORT_EOF

echo "[$(date -Iseconds)] Weekly security report generated: ${WEEKLY_REPORT}"

# Alert if critical
if [ "$OVERALL_STATUS" = "CRITICAL" ]; then
    echo "WEEKLY SECURITY REPORT: CRITICAL issues detected on ${HOSTNAME}. Review ${WEEKLY_REPORT}" | wall 2>/dev/null || true
    logger -p auth.warning "Weekly security report: CRITICAL status on ${HOSTNAME}"
fi

exit 0
