#!/bin/bash
# rkhunter Rootkit Detection Scanner
# Agent 2: Unified security reporting

set -o pipefail

SCRIPT_NAME="rkhunter-scan.sh"
LOG_DIR="/var/log/security/rkhunter"
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
    echo "[$(get_timestamp)] CRITICAL: rkhunter - ${MESSAGE}" >> "${ALERTS_FILE}"
    echo "SECURITY ALERT: rkhunter detected critical issue. Check ${SUMMARY_FILE}" | wall 2>/dev/null || true
    logger -p auth.emerg "Security: rkhunter detected CRITICAL issue" 2>/dev/null || true
}

log_message "Starting rkhunter rootkit scan"

# Preserve previous scan for delta comparison
if [ -f "${LAST_SCAN}" ]; then
    cp "${LAST_SCAN}" "${PREVIOUS_SCAN}"
fi

# Run rkhunter scan
log_message "Running rkhunter --check"
rkhunter --check --skip-keypress --report-warnings-only > "${TEMP_OUTPUT}" 2>&1
SCAN_EXIT_CODE=$?

# Copy full output to last-scan.log
cp "${TEMP_OUTPUT}" "${LAST_SCAN}"

# Initialize counters
SCAN_DATE=$(get_timestamp)
STATUS="OK"
WARNING_DETAILS=""

# Parse the output for rootkits checked
ROOTKITS_CHECKED=$(safe_number "$(grep -oE 'Rootkits checked[^0-9]*([0-9]+)' "${TEMP_OUTPUT}" | grep -oE '[0-9]+' | head -1)")
if [ "${ROOTKITS_CHECKED}" = "0" ] && [ -f /var/log/rkhunter.log ]; then
    ROOTKITS_CHECKED=$(safe_number "$(grep -c 'Checking for' /var/log/rkhunter.log 2>/dev/null)")
fi

# Count rootkits found (any rootkit detection)
ROOTKITS_FOUND=$(safe_number "$(grep -ciE 'rootkit.*found|infected|INFECTED' "${TEMP_OUTPUT}" 2>/dev/null)")

# Count warnings
WARNINGS=$(safe_number "$(grep -c 'Warning:' "${TEMP_OUTPUT}" 2>/dev/null)")

# Extract warning details
WARNING_DETAILS=$(grep "Warning:" "${TEMP_OUTPUT}" 2>/dev/null || echo "")

# Count items checked from rkhunter log if available
ITEMS_CHECKED="0"
if [ -f /var/log/rkhunter.log ]; then
    ITEMS_CHECKED=$(safe_number "$(grep -c 'Checking' /var/log/rkhunter.log 2>/dev/null)")
fi

# Determine status
if [ "${ROOTKITS_FOUND}" -gt 0 ]; then
    STATUS="CRITICAL"
    CRITICAL_COUNT="${ROOTKITS_FOUND}"
elif [ "${WARNINGS}" -gt 0 ]; then
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
    PREV_ROOTKITS=$(safe_number "$(grep '^ROOTKITS_FOUND:' "${PREV_SUMMARY}" 2>/dev/null | cut -d: -f2)")
    DIFF_WARNINGS=$((WARNINGS - PREV_WARNINGS))

    if [ ${DIFF_WARNINGS} -gt 0 ]; then
        DELTA_INFO="New warnings since last scan: +${DIFF_WARNINGS}"
    elif [ ${DIFF_WARNINGS} -lt 0 ]; then
        DELTA_INFO="Warnings resolved since last scan: ${DIFF_WARNINGS}"
    else
        DELTA_INFO="No change in warnings since last scan"
    fi
else
    DELTA_INFO="No previous scan for comparison (first run)"
fi

# Preserve previous summary for delta comparison
if [ -f "${SUMMARY_FILE}" ]; then
    cp "${SUMMARY_FILE}" "${PREV_SUMMARY}"
fi

# Generate summary report
cat > "${SUMMARY_FILE}" << EOF
TOOL: rkhunter
SCAN_DATE: ${SCAN_DATE}
STATUS: ${STATUS}
ITEMS_CHECKED: ${ITEMS_CHECKED}
WARNINGS: ${WARNINGS}
CRITICAL: ${CRITICAL_COUNT}
ROOTKITS_CHECKED: ${ROOTKITS_CHECKED}
ROOTKITS_FOUND: ${ROOTKITS_FOUND}

--- ATTENTION REQUIRED ---
${WARNING_DETAILS:-No warnings found}

--- CHANGES SINCE LAST SCAN ---
${DELTA_INFO}
EOF

log_message "Scan complete. Status: ${STATUS}, Warnings: ${WARNINGS}, Rootkits checked: ${ROOTKITS_CHECKED}"

# Handle critical alerts
if [ "${STATUS}" = "CRITICAL" ]; then
    handle_critical_alert "Rootkit or critical security issue detected. Rootkits found: ${ROOTKITS_FOUND}"
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
