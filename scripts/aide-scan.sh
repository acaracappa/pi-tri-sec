#!/bin/bash
# AIDE File Integrity Scanner
# Agent 3: Unified security reporting

set -o pipefail

SCRIPT_NAME="aide-scan.sh"
LOG_DIR="/var/log/security/aide"
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
    echo "[$(get_timestamp)] CRITICAL: aide - ${MESSAGE}" >> "${ALERTS_FILE}"
    echo "SECURITY ALERT: aide detected critical issue. Check ${SUMMARY_FILE}" | wall 2>/dev/null || true
    logger -p auth.emerg "Security: aide detected CRITICAL issue" 2>/dev/null || true
}

log_message "Starting AIDE file integrity check"

# Check if AIDE database exists
AIDE_DB="/var/lib/aide/aide.db"
if [ ! -f "${AIDE_DB}" ]; then
    log_message "ERROR: AIDE database not found at ${AIDE_DB}. Run 'aideinit' first."
    cat > "${SUMMARY_FILE}" << SUMMARY_EOF
TOOL: aide
SCAN_DATE: $(get_timestamp)
STATUS: WARNING
ITEMS_CHECKED: 0
WARNINGS: 1
CRITICAL: 0
FILES_ADDED: 0
FILES_REMOVED: 0
FILES_CHANGED: 0

--- ATTENTION REQUIRED ---
AIDE database not initialized. Run: sudo aideinit && sudo cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db

--- CHANGES SINCE LAST SCAN ---
N/A - database not initialized
SUMMARY_EOF
    exit 1
fi

# Preserve previous scan for delta comparison
if [ -f "${LAST_SCAN}" ]; then
    cp "${LAST_SCAN}" "${PREVIOUS_SCAN}"
fi

# Run AIDE check
log_message "Running aide --check"
aide --check > "${TEMP_OUTPUT}" 2>&1
SCAN_EXIT_CODE=$?

# Copy full output to last-scan.log
cp "${TEMP_OUTPUT}" "${LAST_SCAN}"

# Initialize counters
SCAN_DATE=$(get_timestamp)
STATUS="OK"
ATTENTION_ITEMS=""

# Parse AIDE output
ITEMS_CHECKED=$(safe_number "$(grep -E '^Total number of entries:' "${TEMP_OUTPUT}" 2>/dev/null | awk '{print $NF}')")
if [ "${ITEMS_CHECKED}" = "0" ]; then
    ITEMS_CHECKED=$(safe_number "$(grep -c '^/' "${TEMP_OUTPUT}" 2>/dev/null)")
fi

# Count added files
FILES_ADDED=$(safe_number "$(grep -E '^Added entries:' "${TEMP_OUTPUT}" 2>/dev/null | awk '{print $NF}')")

# Count removed files
FILES_REMOVED=$(safe_number "$(grep -E '^Removed entries:' "${TEMP_OUTPUT}" 2>/dev/null | awk '{print $NF}')")

# Count changed files
FILES_CHANGED=$(safe_number "$(grep -E '^Changed entries:' "${TEMP_OUTPUT}" 2>/dev/null | awk '{print $NF}')")

# Calculate total changes
TOTAL_CHANGES=$((FILES_ADDED + FILES_REMOVED + FILES_CHANGED))

# Extract changed file details (first 20)
if [ ${TOTAL_CHANGES} -gt 0 ]; then
    ATTENTION_ITEMS=$(grep -E "^(added|removed|changed):" "${TEMP_OUTPUT}" 2>/dev/null | head -20 || echo "")
    if [ -z "${ATTENTION_ITEMS}" ]; then
        ATTENTION_ITEMS=$(grep -E "^[+-f]" "${TEMP_OUTPUT}" 2>/dev/null | head -20 || echo "")
    fi
fi

# Determine status
WARNINGS="0"
CRITICAL_COUNT="0"

if [ ${FILES_CHANGED} -gt 0 ]; then
    CRITICAL_FILES=$(grep -E "(changed:|^f).*(/bin/|/sbin/|/usr/bin/|/usr/sbin/|/etc/passwd|/etc/shadow|/etc/sudoers)" "${TEMP_OUTPUT}" 2>/dev/null || echo "")
    if [ -n "${CRITICAL_FILES}" ]; then
        STATUS="CRITICAL"
        CRITICAL_COUNT="${FILES_CHANGED}"
    else
        STATUS="WARNING"
        WARNINGS="${TOTAL_CHANGES}"
    fi
elif [ ${FILES_ADDED} -gt 5 ] || [ ${FILES_REMOVED} -gt 5 ]; then
    STATUS="WARNING"
    WARNINGS="${TOTAL_CHANGES}"
elif [ ${TOTAL_CHANGES} -gt 0 ]; then
    STATUS="WARNING"
    WARNINGS="${TOTAL_CHANGES}"
fi

# Exit code handling - AIDE returns 0 only if no changes
if [ ${SCAN_EXIT_CODE} -eq 0 ]; then
    STATUS="OK"
    WARNINGS="0"
fi

# Calculate delta if previous scan exists
DELTA_INFO=""
if [ -f "${PREVIOUS_SCAN}" ]; then
    PREV_CHANGES=$(safe_number "$(grep -cE '^(added|removed|changed):' "${PREVIOUS_SCAN}" 2>/dev/null)")
    DIFF_CHANGES=$((TOTAL_CHANGES - PREV_CHANGES))
    
    if [ ${DIFF_CHANGES} -gt 0 ]; then
        DELTA_INFO="More changes detected: +${DIFF_CHANGES} vs previous scan"
    elif [ ${DIFF_CHANGES} -lt 0 ]; then
        DELTA_INFO="Fewer changes detected: ${DIFF_CHANGES} vs previous scan"
    else
        DELTA_INFO="Same number of changes as previous scan"
    fi
else
    DELTA_INFO="No previous scan for comparison (first run)"
fi

# Generate summary report
cat > "${SUMMARY_FILE}" << SUMMARY_EOF
TOOL: aide
SCAN_DATE: ${SCAN_DATE}
STATUS: ${STATUS}
ITEMS_CHECKED: ${ITEMS_CHECKED}
WARNINGS: ${WARNINGS}
CRITICAL: ${CRITICAL_COUNT}
FILES_ADDED: ${FILES_ADDED}
FILES_REMOVED: ${FILES_REMOVED}
FILES_CHANGED: ${FILES_CHANGED}

--- ATTENTION REQUIRED ---
${ATTENTION_ITEMS:-No file integrity changes detected}

--- CHANGES SINCE LAST SCAN ---
${DELTA_INFO}
SUMMARY_EOF

log_message "Scan complete. Status: ${STATUS}, Added: ${FILES_ADDED}, Removed: ${FILES_REMOVED}, Changed: ${FILES_CHANGED}"

# Handle critical alerts
if [ "${STATUS}" = "CRITICAL" ]; then
    handle_critical_alert "File integrity changes detected. Added: ${FILES_ADDED}, Removed: ${FILES_REMOVED}, Changed: ${FILES_CHANGED}"
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
