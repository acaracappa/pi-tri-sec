#!/bin/bash
# Refresh the AIDE baseline after package changes, but only when every change AIDE sees is explained.
# Triggered by aide-refresh.path when the apt hook (apt/99pitrisec-aide-refresh) touches the stamp.
# A change is explained when the path belongs to a package dpkg installed since the baseline and debsums
# verifies those packages, or it is known package-maintenance churn. Anything else: the baseline is kept,
# the unexplained paths are logged, and the next aide-scan reports them as usual.
# Usage: aide-refresh.sh [--dry-run]   (dry run: check and report, never re-initialise)

set -uo pipefail
STAMP=/var/lib/pitrisec/dpkg-changed
DB=/var/lib/aide/aide.db
LOG_DIR=/var/log/security/aide
LOG=${LOG_DIR}/refresh.log
ALERTS=/var/log/security/alerts.txt
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
mkdir -p "$LOG_DIR"
log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG"; }

wait_idle() {  # until no apt/dpkg process has run for 60 s
    local quiet=0
    while [ $quiet -lt 60 ]; do
        # full command lines: unattended-upgrade-shutdown idles all day under the short name "unattended-upgr"
        if pgrep -f '(^|/)(apt|apt-get|aptitude|dpkg)( |$)|/unattended-upgrade( |$)' >/dev/null; then quiet=0; else quiet=$((quiet + 10)); fi
        sleep 10
    done
}

refresh_once() {
    [ -f "$DB" ] || { log "no AIDE baseline; run aideinit"; return 1; }
    [ "$STAMP" -nt "$DB" ] || [ $DRY = 1 ] || { log "baseline is newer than the last package change; nothing to do"; return 0; }
    local since; since=$(date -d "@$(stat -c %Y "$DB")" '+%F %T')

    # Packages dpkg touched since the baseline (dpkg.log lines are "date time action pkg:arch ...").
    local work; work=$(mktemp -d)
    zcat -f /var/log/dpkg.log.1 /var/log/dpkg.log 2>/dev/null | awk -v s="$since" '($1" "$2) >= s' > "$work/dpkg"
    awk '$3=="status" && $4=="installed" {print $5}' "$work/dpkg" | sort -u > "$work/installed"
    awk '$3=="remove" || $3=="purge" {print $4}' "$work/dpkg" | sort -u > "$work/removed"
    log "since $since: $(wc -l < "$work/installed") packages installed/upgraded, $(wc -l < "$work/removed") removed"

    # Every path those packages own, from dpkg's file lists.
    : > "$work/owned"
    while read -r p; do
        for l in "/var/lib/dpkg/info/${p}.list" "/var/lib/dpkg/info/${p%%:*}.list"; do [ -f "$l" ] && cat "$l" >> "$work/owned" && break; done
    done < "$work/installed"
    sort -u -o "$work/owned" "$work/owned"

    # debsums: the installed files must match the packages (conffiles excluded; local edits there are expected).
    local bad=""
    if [ -s "$work/installed" ]; then
        bad=$(xargs -a "$work/installed" debsums -s 2>&1 | grep -E 'changed file|missing file|REPLACED|FAILED' || true)
    fi

    # What AIDE sees, as one path per line.
    aide --config=/etc/aide/aide.conf --check > "$work/aide" 2>&1
    local rc=$?
    if [ $rc -ge 14 ]; then log "aide --check failed (exit $rc); baseline kept"; rm -rf "$work"; return 1; fi
    awk '/^(Added|Removed|Changed) entries:/{on=1; next} /^Detailed information/{on=0} on && /^[a-z][^:]*: \//{sub(/^[^:]*: /,""); print}' "$work/aide" | sort -u > "$work/paths"

    # Churn that package maintenance creates outside dpkg's file lists.
    local churn='^/var/lib/(dpkg|apt|ucf|systemd|initramfs-tools|polkit-1|python)/|^/var/(cache|log)/|^/etc/ld\.so\.cache$|^/etc/alternatives/|^/usr/share/info/dir|^/usr/share/mime/|icon-theme\.cache$|loaders\.cache$|^/usr/lib/locale/locale-archive$|^/etc/apparmor\.d/cache|^/var/lib/aide/'
    grep -qE '^(raspi-firmware|linux-image|initramfs-tools)' "$work/installed" && churn="$churn|^/boot/firmware/"
    grep -qE '^ca-certificates' "$work/installed" && churn="$churn|^/etc/ssl/certs/"
    : > "$work/unexplained"
    while read -r path; do
        grep -qxF "$path" "$work/owned" && continue
        [[ $path =~ $churn ]] && continue
        if [[ $path == */__pycache__* ]]; then  # bytecode compiled by a package's postinst from its own .py files
            src=${path%/__pycache__*}; grep -qxF "$src" "$work/owned" && continue
        fi
        echo "$path" >> "$work/unexplained"
    done < "$work/paths"

    log "AIDE reports $(wc -l < "$work/paths") changed paths; $(wc -l < "$work/unexplained") unexplained"
    local reason=""
    [ -n "$bad" ] && reason="debsums found modified package files"
    [ -s "$work/removed" ] && reason="${reason:+$reason; }packages were removed ($(paste -sd' ' "$work/removed")): review removals manually"
    [ -s "$work/unexplained" ] && reason="${reason:+$reason; }changes not explained by the updates"
    if [ -n "$reason" ]; then
        log "baseline KEPT: $reason"
        [ -n "$bad" ] && printf '  debsums: %s\n' "$bad" | tee -a "$LOG"
        sed 's/^/  unexplained: /' "$work/unexplained" | head -50 | tee -a "$LOG"
        [ $DRY = 0 ] && echo "[$(date -Iseconds)] WARNING: aide-refresh kept the baseline: $reason (see $LOG)" >> "$ALERTS"
        rm -rf "$work"; return 2
    fi
    if [ $DRY = 1 ]; then log "dry run: would re-initialise the baseline"; rm -rf "$work"; return 0; fi
    log "all changes explained by $(wc -l < "$work/installed") verified packages; re-initialising the baseline"
    aideinit -y -f > /dev/null 2>&1 && log "baseline refreshed" || { log "aideinit failed"; rm -rf "$work"; return 1; }
    /usr/local/bin/aide-scan.sh > /dev/null 2>&1
    [ -x /usr/local/bin/pitrisec_exporter.py ] && /usr/local/bin/pitrisec_exporter.py > /dev/null 2>&1
    rm -rf "$work"; return 0
}

if [ $DRY = 1 ]; then refresh_once; exit $?; fi
wait_idle
started=$(date +%s)
refresh_once; rc=$?
# More packages may have been installed while this ran; go round again if so.
while [ -f "$STAMP" ] && [ "$(stat -c %Y "$STAMP")" -gt "$started" ] && [ $rc -eq 0 ]; do
    wait_idle; started=$(date +%s); refresh_once; rc=$?
done
exit $rc
