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
   | Sun 2AM |         | Daily 2:30|         | Sun 3AM|
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
| rkhunter-scan.timer | Daily 02:30 | Rootkit scan |
| aide-scan.timer | Sun 03:00 | Integrity check |
| security-report.timer | Sun 04:00 | Weekly report |
| aide-refresh.path | after every apt/dpkg run | Re-baseline AIDE if the updates explain every change |

## Install

On a fresh Raspberry Pi OS (Debian 13 trixie) host, as root:

```bash
git clone https://github.com/acaracappa/pi-tri-sec.git && cd pi-tri-sec
sudo ./setup.sh
```

`setup.sh` installs the packages, disables the distro timers that clash with these, configures rkhunter (mirror updates,
known false positives), turns off root SSH login, initialises AIDE (sha512, with excludes for paths that change on every boot),
copies the scripts to `/usr/local/bin/`, and enables the timers and the update hook. Package updates re-baseline AIDE on their own
(see Maintenance); re-run `sudo aideinit -y -f` after any other intentional system change.

## Prometheus exporter (optional)

`exporter/pitrisec_exporter.py` reads each tool's `summary.txt` and writes `pitrisec_status{tool}` (0 OK, 1 WARNING, 2 CRITICAL;
a missing STATUS counts as 2) for node_exporter's textfile collector (`/var/lib/prometheus/node-exporter/`), every 15 minutes:

```bash
sudo cp exporter/pitrisec_exporter.py /usr/local/bin/
sudo cp exporter/pitrisec-exporter.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now pitrisec-exporter.timer
```

## Summary format

Each scan writes `/var/log/security/<tool>/summary.txt`:

```
TOOL: <tool_name>
SCAN_DATE: <ISO timestamp>
STATUS: OK | WARNING | CRITICAL
ITEMS_CHECKED: <count>
WARNINGS: <count>
CRITICAL: <count>
HARDENING_INDEX: <0-100>          (lynis only)

--- ATTENTION REQUIRED ---
<only actionable items, one per line>

--- CHANGES SINCE LAST SCAN ---
<delta from previous scan, if applicable>
```

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

### AIDE baseline after package updates (automatic)
An apt hook (`/etc/apt/apt.conf.d/99pitrisec-aide-refresh`) touches `/var/lib/pitrisec/dpkg-changed` after every dpkg run, and
`aide-refresh.path` starts `aide-refresh.sh` once apt has been idle for a minute. It takes the packages installed since the
baseline from `dpkg.log`, verifies them with `debsums`, and matches every path `aide --check` reports against the files those
packages own (plus known maintenance churn: apt and dpkg state, caches, compiled Python). If everything is explained it re-runs
`aideinit`; otherwise it keeps the baseline, logs the unexplained paths to `/var/log/security/aide/refresh.log`, and adds a
line to `alerts.txt`. Package removals always need a manual review. Check without changing anything:
```bash
sudo /usr/local/bin/aide-refresh.sh --dry-run
```

### Update AIDE baseline after other legitimate changes
After intentional changes that are not package updates (new scripts, config edits):
```bash
sudo aideinit -y -f
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

## Alert Behavior

When any scan detects CRITICAL status:
1. Appends to `/var/log/security/alerts.txt`
2. Broadcasts via `wall` command
3. Logs to systemd journal with priority `emerg`
