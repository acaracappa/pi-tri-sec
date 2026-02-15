#!/bin/bash
# Lynis Security Auditor Scanner
# Agent 1: Unified security reporting

set -o pipefail

SCRIPT_NAME="lynis-scan.sh"
LOG_DIR="/var/log/security/lynis"
SUMMARY_FILE="${LOG_DIR}/summary.txt"
LAST_SCAN="${LOG_DIR}/last-scan.log"
PREVIOUS_SCAN="${LOG_DIR}/previous-scan.log"
ALERTS_FILE="/var/log/security/alerts.txt"
TEMP_OUTPUT=$(mktemp)

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# Function to get ISO timestamp
get_timestamp() {
    date -Iseconds
}

# Function to log messages
log_message() {
    echo "[$(get_timestamp)] $1"
}

# Function to safely get a number (returns 0 if empty/invalid)
safe_number() {
    local val="$1"
    val=$(echo "$val" | tr -d '[:space:]' | head -1)
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "$val"
    else
        echo "0"
    fi
}

# Function to handle critical alerts
handle_critical_alert() {
    local MESSAGE="$1"
    echo "[$(get_timestamp)] CRITICAL: lynis - ${MESSAGE}" >> "${ALERTS_FILE}"
    echo "SECURITY ALERT: lynis detected critical issue. Check ${SUMMARY_FILE}" | wall 2>/dev/null || true
    logger -p auth.emerg "Security: lynis detected CRITICAL issue" 2>/dev/null || true
}

log_message "Starting Lynis security audit"

# Preserve previous scan for delta comparison
if [ -f "${LAST_SCAN}" ]; then
    cp "${LAST_SCAN}" "${PREVIOUS_SCAN}"
fi

# Run lynis audit
log_message "Running lynis audit system"
lynis audit system --quiet --no-colors > "${TEMP_OUTPUT}" 2>&1
SCAN_EXIT_CODE=$?

# Copy full output to last-scan.log
cp "${TEMP_OUTPUT}" "${LAST_SCAN}"

# Initialize counters
SCAN_DATE=$(get_timestamp)
STATUS="OK"
WARNING_DETAILS=""
SUGGESTIONS=""

# Parse lynis report file for detailed metrics
LYNIS_REPORT="/var/log/lynis-report.dat"

HARDENING_INDEX="0"
ITEMS_CHECKED="0"
WARNINGS="0"
SUGGESTION_COUNT="0"

if [ -f "${LYNIS_REPORT}" ]; then
    # Get hardening index
    HARDENING_INDEX=$(safe_number "$(grep '^hardening_index=' "${LYNIS_REPORT}" | cut -d= -f2 | head -1)")
    
    # Count tests performed
    ITEMS_CHECKED=$(safe_number "$(grep -c '^test=' "${LYNIS_REPORT}" 2>/dev/null)")
    
    # Count warnings
    WARNINGS=$(safe_number "$(grep -c '^warning\[\]=' "${LYNIS_REPORT}" 2>/dev/null)")
    
    # Extract warning details
    WARNING_DETAILS=$(grep "^warning\[\]=" "${LYNIS_REPORT}" 2>/dev/null | cut -d= -f2 | sed 's/|/: /' || echo "")
    
    # Count suggestions
    SUGGESTION_COUNT=$(safe_number "$(grep -c '^suggestion\[\]=' "${LYNIS_REPORT}" 2>/dev/null)")
    
    # Get top suggestions
    SUGGESTIONS=$(grep "^suggestion\[\]=" "${LYNIS_REPORT}" 2>/dev/null | head -10 | cut -d= -f2 | sed 's/|/: /' || echo "")
fi

# Determine status based on hardening index and warnings
if [ "${HARDENING_INDEX}" -lt 50 ] || [ "${WARNINGS}" -gt 10 ]; then
    STATUS="CRITICAL"
    CRITICAL_COUNT="${WARNINGS}"
elif [ "${WARNINGS}" -gt 0 ] || [ "${HARDENING_INDEX}" -lt 70 ]; then
    STATUS="WARNING"
    CRITICAL_COUNT="0"
else
    CRITICAL_COUNT="0"
fi

# Calculate delta using previous summary (consistent data source)
DELTA_INFO=""
PREV_SUMMARY="${LOG_DIR}/previous-summary.txt"
if [ -f "${PREV_SUMMARY}" ]; then
    PREV_WARNINGS=$(safe_number "$(grep '^WARNINGS:' "${PREV_SUMMARY}" 2>/dev/null | cut -d: -f2)")
    PREV_HARDENING=$(safe_number "$(grep '^HARDENING_INDEX:' "${PREV_SUMMARY}" 2>/dev/null | cut -d: -f2)")
    DIFF_WARNINGS=$((WARNINGS - PREV_WARNINGS))
    DIFF_HARDENING=$((HARDENING_INDEX - PREV_HARDENING))

    DELTA_PARTS=""
    if [ ${DIFF_WARNINGS} -gt 0 ]; then
        DELTA_PARTS="New warnings: +${DIFF_WARNINGS}"
    elif [ ${DIFF_WARNINGS} -lt 0 ]; then
        DELTA_PARTS="Warnings resolved: ${DIFF_WARNINGS}"
    else
        DELTA_PARTS="Warnings unchanged"
    fi

    if [ ${DIFF_HARDENING} -ne 0 ]; then
        DELTA_PARTS="${DELTA_PARTS}; Hardening index change: ${DIFF_HARDENING}"
    fi
    DELTA_INFO="${DELTA_PARTS}"
else
    DELTA_INFO="No previous scan for comparison (first run)"
fi

# Preserve previous summary for delta comparison
if [ -f "${SUMMARY_FILE}" ]; then
    cp "${SUMMARY_FILE}" "${PREV_SUMMARY}"
fi

# Generate summary report
cat > "${SUMMARY_FILE}" << SUMMARY_EOF
TOOL: lynis
SCAN_DATE: ${SCAN_DATE}
STATUS: ${STATUS}
ITEMS_CHECKED: ${ITEMS_CHECKED}
WARNINGS: ${WARNINGS}
CRITICAL: ${CRITICAL_COUNT}
HARDENING_INDEX: ${HARDENING_INDEX}
SUGGESTIONS_COUNT: ${SUGGESTION_COUNT}

--- ATTENTION REQUIRED ---
${WARNING_DETAILS:-No warnings found}

--- TOP SUGGESTIONS ---
${SUGGESTIONS:-No suggestions}

--- CHANGES SINCE LAST SCAN ---
${DELTA_INFO}
SUMMARY_EOF

log_message "Scan complete. Status: ${STATUS}, Hardening Index: ${HARDENING_INDEX}, Warnings: ${WARNINGS}"

# Handle critical alerts
if [ "${STATUS}" = "CRITICAL" ]; then
    handle_critical_alert "Security audit found critical issues. Hardening index: ${HARDENING_INDEX}, Warnings: ${WARNINGS}"
fi

# Cleanup
rm -f "${TEMP_OUTPUT}"

# Exit with appropriate code
case "${STATUS}" in
    "OK") exit 0 ;;
    "WARNING") exit 1 ;;
    "CRITICAL") exit 2 ;;
    *) exit 0 ;;
esac
