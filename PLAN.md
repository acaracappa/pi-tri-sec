# Security Monitoring Stack - Project Plan

## Overview

Deploy three security monitoring tools (Lynis, rkhunter, AIDE) via parallel agent execution, with unified weekly reporting.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Weekly Report Aggregator                      │
│                  /var/log/security/weekly-report                 │
└─────────────────────────────────────────────────────────────────┘
        ▲                    ▲                    ▲
        │                    │                    │
┌───────┴───────┐   ┌────────┴────────┐   ┌──────┴──────┐
│  Agent 1:     │   │  Agent 2:       │   │  Agent 3:   │
│  Lynis        │   │  rkhunter       │   │  AIDE       │
│  Auditor      │   │  Rootkit Hunter │   │  Integrity  │
└───────────────┘   └─────────────────┘   └─────────────┘
```

---

## Reporting Requirements (All Agents Must Follow)

### Standard Output Location
```
/var/log/security/
├── lynis/
│   ├── last-scan.log        # Full scan output
│   └── summary.txt          # Distilled findings
├── rkhunter/
│   ├── last-scan.log
│   └── summary.txt
├── aide/
│   ├── last-scan.log
│   └── summary.txt
└── weekly-report.txt         # Consolidated report
```

### Summary Format (Each Tool)
Each agent must produce `summary.txt` with this structure:
```
TOOL: <tool_name>
SCAN_DATE: <ISO timestamp>
STATUS: OK | WARNING | CRITICAL
ITEMS_CHECKED: <count>
WARNINGS: <count>
CRITICAL: <count>

--- ATTENTION REQUIRED ---
<Only actionable items, one per line>

--- CHANGES SINCE LAST SCAN ---
<Delta from previous scan, if applicable>
```

### Severity Levels
- **OK**: No issues found
- **WARNING**: Non-critical findings (hardening suggestions, minor anomalies)
- **CRITICAL**: Immediate attention required (rootkits, unauthorized changes, vulnerabilities)

### Immediate Alerting (CRITICAL findings)
When any scan detects CRITICAL status:
1. Write to `/var/log/security/alerts.txt` with timestamp
2. Send system-wide notification via `wall` command
3. Log to systemd journal with priority `emerg`

Each scan script must include:
```bash
if [ "$STATUS" = "CRITICAL" ]; then
    echo "[$(date -Iseconds)] CRITICAL: $TOOL - $MESSAGE" >> /var/log/security/alerts.txt
    echo "SECURITY ALERT: $TOOL detected critical issue. Check /var/log/security/$TOOL/summary.txt" | wall
    logger -p auth.emerg "Security: $TOOL detected CRITICAL issue"
fi
```

---

## Agent 1: Lynis Security Auditor

**Responsibility**: System-wide security audit and hardening recommendations

### Tasks
1. Install lynis package
2. Create `/var/log/security/lynis/` directory
3. Create scan script at `/usr/local/bin/lynis-scan.sh`:
   - Run `lynis audit system --quiet`
   - Parse output for warnings/suggestions
   - Generate `summary.txt` in standard format
   - Trigger immediate alert if CRITICAL (wall + alerts.txt + journal)
   - Exit code reflects severity (0=OK, 1=WARNING, 2=CRITICAL)
4. Create systemd timer for weekly scan (Sunday 02:00 EST)
5. Create systemd service unit for the scan script
6. Run initial baseline scan

### Output Metrics for Weekly Report
- Hardening Index score (0-100)
- Count of warnings by category
- New suggestions since last scan
- Tests passed/failed/skipped

---

## Agent 2: rkhunter Rootkit Detection

**Responsibility**: Rootkit, backdoor, and suspicious file detection

### Tasks
1. Install rkhunter package
2. Create `/var/log/security/rkhunter/` directory
3. Update rkhunter database: `rkhunter --update`
4. Set baseline properties: `rkhunter --propupd`
5. Create scan script at `/usr/local/bin/rkhunter-scan.sh`:
   - Run `rkhunter --check --skip-keypress`
   - Parse for warnings (grep "Warning:")
   - Generate `summary.txt` in standard format
   - Trigger immediate alert if CRITICAL (wall + alerts.txt + journal)
6. Create systemd timer for weekly scan (Sunday 02:30 EST)
7. Create systemd service unit for the scan script
8. Run initial baseline scan

### Output Metrics for Weekly Report
- Rootkits checked/found
- Suspicious files detected
- System command changes
- Network port anomalies

---

## Agent 3: AIDE File Integrity

**Responsibility**: Detect unauthorized changes to critical system files

### Tasks
1. Install aide package
2. Create `/var/log/security/aide/` directory
3. Configure `/etc/aide/aide.conf` to monitor:
   - `/etc/` (config files)
   - `/bin/`, `/sbin/`, `/usr/bin/`, `/usr/sbin/` (binaries)
   - `/boot/` (kernel/bootloader)
4. Initialize baseline database: `aideinit`
5. Create scan script at `/usr/local/bin/aide-scan.sh`:
   - Run `aide --check`
   - Parse for added/removed/changed files
   - Generate `summary.txt` in standard format
   - Trigger immediate alert if CRITICAL (wall + alerts.txt + journal)
6. Create systemd timer for weekly scan (Sunday 03:00 EST)
7. Create systemd service unit for the scan script
8. Document baseline update procedure (required after legitimate changes)
9. Run initial scan (will show changes vs baseline)

### Output Metrics for Weekly Report
- Files added since baseline
- Files removed since baseline
- Files modified since baseline
- Config files changed

---

## Weekly Report Aggregator

**Created after all agents complete**

### Aggregator Script: `/usr/local/bin/security-weekly-report.sh`
```bash
#!/bin/bash
# Runs Sunday 04:00 after all scans complete
# Consolidates all summary.txt into weekly-report.txt
```

### Weekly Report Format
```
================================================================================
                    WEEKLY SECURITY REPORT - <hostname>
                    Generated: <timestamp>
================================================================================

EXECUTIVE SUMMARY
-----------------
Overall Status: [OK | WARNING | CRITICAL]
Lynis Score: XX/100
Rootkits Found: X
File Integrity Changes: X

ATTENTION REQUIRED
------------------
[Consolidated critical/warning items from all tools]

DETAILED FINDINGS
-----------------
[Lynis Summary]
[rkhunter Summary]
[AIDE Summary]

================================================================================
```

### Delivery
- Write to `/var/log/security/weekly-report.txt`
- Read manually via SSH or local terminal

---

## Pre-Setup (Before Parallel Agents)

Create shared infrastructure before launching agents:

```bash
# Create directory structure
sudo mkdir -p /var/log/security/{lynis,rkhunter,aide}
sudo touch /var/log/security/alerts.txt
sudo chmod 755 /var/log/security
sudo chmod 644 /var/log/security/alerts.txt
```

---

## Systemd Timers Schedule (EST timezone)

| Timer | Time | Tool |
|-------|------|------|
| lynis-scan.timer | Sun 02:00 EST | Lynis audit |
| rkhunter-scan.timer | Sun 02:30 EST | Rootkit scan |
| aide-scan.timer | Sun 03:00 EST | Integrity check |
| security-report.timer | Sun 04:00 EST | Aggregate report |

All timers use `OnCalendar=Sun *-*-* HH:MM:00` format in systemd.

---

## Verification

After all agents complete:

1. **Check all services enabled**:
   ```bash
   systemctl list-timers | grep -E "lynis|rkhunter|aide|security"
   ```

2. **Verify directory structure**:
   ```bash
   ls -la /var/log/security/*/
   ```

3. **Run each scan manually**:
   ```bash
   sudo /usr/local/bin/lynis-scan.sh
   sudo /usr/local/bin/rkhunter-scan.sh
   sudo /usr/local/bin/aide-scan.sh
   sudo /usr/local/bin/security-weekly-report.sh
   ```

4. **Review generated report**:
   ```bash
   cat /var/log/security/weekly-report.txt
   ```

---

## Agent Execution

### Phase 1: Pre-Setup (Main Agent)
Create shared directory structure and alerts.txt file.

### Phase 2: Parallel Agent Execution
Launch three agents simultaneously:

| Agent | Tool | Deliverables |
|-------|------|--------------|
| Agent 1 | Lynis | lynis-scan.sh, lynis-scan.service, lynis-scan.timer |
| Agent 2 | rkhunter | rkhunter-scan.sh, rkhunter-scan.service, rkhunter-scan.timer |
| Agent 3 | AIDE | aide-scan.sh, aide-scan.service, aide-scan.timer |

Each agent must:
1. Install their tool
2. Create scan script in `/usr/local/bin/`
3. Create systemd service and timer
4. Enable the timer
5. Run initial scan to verify functionality
6. Report completion status

### Phase 3: Post-Setup (Main Agent)
After all agents complete:
1. Create `/usr/local/bin/security-weekly-report.sh` aggregator
2. Create `security-report.service` and `security-report.timer`
3. Enable aggregator timer
4. Run verification tests
