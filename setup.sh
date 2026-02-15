#!/bin/bash
# Pi-Tri-Sec Setup Script
# Configures Lynis, rkhunter, and AIDE security monitoring on a fresh Raspberry Pi
# Tested on: Debian 13 (trixie) aarch64

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="${REPO_DIR}/scripts"
SYSTEMD_DIR="${REPO_DIR}/systemd"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root (use sudo)"
    exit 1
fi

# Verify repo structure
for f in "${SCRIPTS_DIR}/lynis-scan.sh" "${SCRIPTS_DIR}/rkhunter-scan.sh" \
         "${SCRIPTS_DIR}/aide-scan.sh" "${SCRIPTS_DIR}/security-weekly-report.sh"; do
    if [ ! -f "$f" ]; then
        err "Missing script: $f"
        exit 1
    fi
done

for f in "${SYSTEMD_DIR}/lynis-scan.service" "${SYSTEMD_DIR}/lynis-scan.timer" \
         "${SYSTEMD_DIR}/rkhunter-scan.service" "${SYSTEMD_DIR}/rkhunter-scan.timer" \
         "${SYSTEMD_DIR}/aide-scan.service" "${SYSTEMD_DIR}/aide-scan.timer" \
         "${SYSTEMD_DIR}/security-report.service" "${SYSTEMD_DIR}/security-report.timer"; do
    if [ ! -f "$f" ]; then
        err "Missing systemd unit: $f"
        exit 1
    fi
done

log "Pi-Tri-Sec setup starting"

# --- Step 1: Install packages ---
log "Installing lynis, rkhunter, aide..."
apt-get update -qq
apt-get install -y -qq lynis rkhunter aide > /dev/null 2>&1
log "Packages installed"

# --- Step 2: Disable distro-provided timers that conflict with ours ---
log "Disabling distro-provided timers..."
systemctl disable --now lynis.timer 2>/dev/null || true
systemctl disable --now dailyaidecheck.timer 2>/dev/null || true

# --- Step 3: Configure rkhunter ---
log "Configuring rkhunter..."

# Fix mirror/update settings (Debian defaults block updates)
sed -i 's|^WEB_CMD=/bin/false|WEB_CMD=""|' /etc/rkhunter.conf
sed -i 's|^UPDATE_MIRRORS=0|UPDATE_MIRRORS=1|' /etc/rkhunter.conf
sed -i 's|^MIRRORS_MODE=1|MIRRORS_MODE=0|' /etc/rkhunter.conf

# Whitelist known false positives
# /etc/.updated is a normal systemd timestamp file
grep -q '^ALLOWHIDDENFILE=/etc/.updated' /etc/rkhunter.conf || \
    sed -i '/^#ALLOWHIDDENFILE=\/etc\/.etckeeper/a ALLOWHIDDENFILE=/etc/.updated' /etc/rkhunter.conf

# Accept key-only root login (matches default sshd behavior)
sed -i 's|^#ALLOW_SSH_ROOT_USER=no|ALLOW_SSH_ROOT_USER=without-password|' /etc/rkhunter.conf
# If already uncommented with a different value, update it
sed -i 's|^ALLOW_SSH_ROOT_USER=no|ALLOW_SSH_ROOT_USER=without-password|' /etc/rkhunter.conf

# Update rkhunter database
log "Updating rkhunter signatures..."
rkhunter --update 2>/dev/null || warn "rkhunter --update returned non-zero (may be normal if already current)"
rkhunter --propupd > /dev/null 2>&1
log "rkhunter configured"

# --- Step 4: Ensure explicit PermitRootLogin in sshd ---
if ! grep -rq '^PermitRootLogin' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null; then
    log "Adding explicit PermitRootLogin to sshd config..."
    echo "PermitRootLogin without-password" > /etc/ssh/sshd_config.d/hardening.conf
fi

# --- Step 5: Initialize AIDE database ---
if [ ! -f /var/lib/aide/aide.db ]; then
    log "Initializing AIDE database (this takes a few minutes)..."
    aideinit
    log "AIDE database initialized"
else
    log "AIDE database already exists, skipping init"
fi

# --- Step 6: Deploy scripts ---
log "Deploying scan scripts to /usr/local/bin/..."
cp "${SCRIPTS_DIR}/lynis-scan.sh" /usr/local/bin/
cp "${SCRIPTS_DIR}/rkhunter-scan.sh" /usr/local/bin/
cp "${SCRIPTS_DIR}/aide-scan.sh" /usr/local/bin/
cp "${SCRIPTS_DIR}/security-weekly-report.sh" /usr/local/bin/
chmod +x /usr/local/bin/lynis-scan.sh \
         /usr/local/bin/rkhunter-scan.sh \
         /usr/local/bin/aide-scan.sh \
         /usr/local/bin/security-weekly-report.sh
log "Scripts deployed"

# --- Step 7: Deploy systemd units ---
log "Deploying systemd timers and services..."
cp "${SYSTEMD_DIR}"/*.service "${SYSTEMD_DIR}"/*.timer /etc/systemd/system/
systemctl daemon-reload

# Enable and start timers
systemctl enable --now lynis-scan.timer
systemctl enable --now rkhunter-scan.timer
systemctl enable --now aide-scan.timer
systemctl enable --now security-report.timer
log "Timers enabled"

# --- Step 8: Verify ---
log "Verifying deployment..."
TIMERS_OK=0
for timer in lynis-scan rkhunter-scan aide-scan security-report; do
    if systemctl is-enabled "${timer}.timer" > /dev/null 2>&1; then
        TIMERS_OK=$((TIMERS_OK + 1))
    else
        warn "${timer}.timer is not enabled"
    fi
done

SCRIPTS_OK=0
for script in lynis-scan.sh rkhunter-scan.sh aide-scan.sh security-weekly-report.sh; do
    if [ -x "/usr/local/bin/${script}" ]; then
        SCRIPTS_OK=$((SCRIPTS_OK + 1))
    else
        warn "/usr/local/bin/${script} missing or not executable"
    fi
done

echo ""
log "========================================="
log "  Pi-Tri-Sec setup complete"
log "========================================="
log "  Scripts deployed: ${SCRIPTS_OK}/4"
log "  Timers enabled:  ${TIMERS_OK}/4"
log ""
log "  Schedule (Sundays):"
log "    02:00 - Lynis security audit"
log "    02:30 - rkhunter rootkit scan"
log "    03:00 - AIDE file integrity check"
log "    04:00 - Weekly report aggregation"
log ""
log "  Reports: /var/log/security/weekly-report.txt"
log ""
log "  Run a manual test:"
log "    sudo /usr/local/bin/lynis-scan.sh"
log "    sudo /usr/local/bin/rkhunter-scan.sh"
log "    sudo /usr/local/bin/aide-scan.sh"
log "    sudo /usr/local/bin/security-weekly-report.sh"
log "========================================="
