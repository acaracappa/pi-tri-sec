# Pi-Tri-Sec

Security monitoring stack for Raspberry Pi using three complementary tools with unified weekly reporting.

## Tools

| Tool | Purpose |
|------|---------|
| **Lynis** | System-wide security audit and hardening recommendations |
| **rkhunter** | Rootkit, backdoor, and suspicious file detection |
| **AIDE** | File integrity monitoring for critical system files |

## Architecture

```
Weekly Report Aggregator (/var/log/security/weekly-report.txt)
        ^                    ^                    ^
        |                    |                    |
   +---------+         +-----------+         +--------+
   |  Lynis  |         |  rkhunter |         |  AIDE  |
   | Sun 2AM |         |  Sun 2:30 |         | Sun 3AM|
   +---------+         +-----------+         +--------+
```

## Output Location

```
/var/log/security/
├── lynis/
│   ├── last-scan.log
│   └── summary.txt
├── rkhunter/
│   ├── last-scan.log
│   └── summary.txt
├── aide/
│   ├── last-scan.log
│   └── summary.txt
├── alerts.txt           # CRITICAL findings (immediate)
└── weekly-report.txt    # Consolidated report (Sun 4AM)
```

## Scan Schedule (EST)

| Timer | Time | Tool |
|-------|------|------|
| lynis-scan.timer | Sun 02:00 | Security audit |
| rkhunter-scan.timer | Sun 02:30 | Rootkit scan |
| aide-scan.timer | Sun 03:00 | Integrity check |
| security-report.timer | Sun 04:00 | Weekly report |

## Implementation Status

**Completed: 2026-01-26**

### Setup Tasks
- [x] Directory structure `/var/log/security/{lynis,rkhunter,aide}`
- [x] Packages installed (lynis, rkhunter, aide)
- [x] Custom scan scripts created in `/usr/local/bin/`
- [x] All systemd timers created and enabled
- [x] AIDE database initialized (44MB baseline)
- [x] rkhunter database updated and baseline set
- [x] Weekly report aggregator created
- [x] Initial baseline scans completed
- [x] Weekly report generated successfully

### Hardening Applied
- [x] SSH `PermitRootLogin` set to `no`

### Final Scan Results (2026-01-26)

| Tool | Status | Details |
|------|--------|---------|
| Lynis | WARNING | Hardening score: 72/100, 1 warning, 42 suggestions |
| rkhunter | WARNING | 1256 rootkits checked, 0 found, 2 benign warnings |
| AIDE | OK | Baseline established, no changes |

### Remaining Warnings (Benign)
- **Lynis**: Missing security repository in apt sources (optional)
- **rkhunter**: Suspicious file types in `/dev` (normal on Linux)
- **rkhunter**: Hidden file `/etc/.updated` (system timestamp)

## Manual Commands

Check timer status:
```bash
systemctl list-timers | grep -E "lynis|rkhunter|aide|security"
```

Run scans manually:
```bash
sudo /usr/local/bin/lynis-scan.sh
sudo /usr/local/bin/rkhunter-scan.sh
sudo /usr/local/bin/aide-scan.sh
sudo /usr/local/bin/security-weekly-report.sh
```

View weekly report:
```bash
cat /var/log/security/weekly-report.txt
```

## Maintenance

### Update AIDE baseline after legitimate changes
After system updates or intentional config changes, update the AIDE baseline:
```bash
sudo aideinit
sudo cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

### Update rkhunter baseline after system changes
```bash
sudo rkhunter --propupd
```

### View recent alerts
```bash
cat /var/log/security/alerts.txt
```

## Installed Components

### Scan Scripts
- `/usr/local/bin/lynis-scan.sh`
- `/usr/local/bin/rkhunter-scan.sh`
- `/usr/local/bin/aide-scan.sh`
- `/usr/local/bin/security-weekly-report.sh`

### Systemd Units
- `/etc/systemd/system/lynis-scan.{service,timer}`
- `/etc/systemd/system/rkhunter-scan.{service,timer}`
- `/etc/systemd/system/aide-scan.{service,timer}`
- `/etc/systemd/system/security-report.{service,timer}`

### Databases
- `/var/lib/aide/aide.db` - AIDE file integrity baseline
- `/var/lib/rkhunter/db/` - rkhunter detection signatures

## Project Files

```
pi-tri-sec/
├── PLAN.md                 # Detailed implementation plan
├── README.md               # This file
├── scripts/
│   ├── aide-scan.sh        # AIDE integrity check script
│   ├── lynis-scan.sh       # Lynis security audit script
│   ├── rkhunter-scan.sh    # rkhunter rootkit scan script
│   └── security-weekly-report.sh  # Weekly report aggregator
└── systemd/
    ├── aide-scan.service
    ├── aide-scan.timer
    ├── lynis-scan.service
    ├── lynis-scan.timer
    ├── rkhunter-scan.service
    ├── rkhunter-scan.timer
    ├── security-report.service
    └── security-report.timer
```

### Reinstallation
To reinstall from these backups:
```bash
# Copy scripts
sudo cp scripts/*.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/*-scan.sh /usr/local/bin/security-weekly-report.sh

# Copy systemd units
sudo cp systemd/* /etc/systemd/system/
sudo systemctl daemon-reload

# Enable timers
sudo systemctl enable --now lynis-scan.timer rkhunter-scan.timer aide-scan.timer security-report.timer
```

## Alert Behavior

When any scan detects CRITICAL status:
1. Appends to `/var/log/security/alerts.txt`
2. Broadcasts via `wall` command
3. Logs to systemd journal with priority `emerg`
