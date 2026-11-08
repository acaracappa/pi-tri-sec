#!/usr/bin/env python3
"""Expose pi-tri-sec summary results to the node exporter textfile collector."""
import datetime, os, re

BASE = "/var/log/security"
OUT = "/var/lib/prometheus/node-exporter/pitrisec.prom"
LEVEL = {"OK": 0, "WARNING": 1, "CRITICAL": 2}
lines = ["# TYPE pitrisec_status gauge"]
worst = 0
for tool in ("lynis", "rkhunter", "aide"):
    try:
        text = open(f"{BASE}/{tool}/summary.txt").read()
    except OSError:
        continue
    kv = dict(re.findall(r"^([A-Z_]+):\s*(.*)$", text, re.M))
    lvl = LEVEL.get(kv.get("STATUS", ""), 2)
    worst = max(worst, lvl)
    lines.append(f'pitrisec_status{{tool="{tool}"}} {lvl}')
    for key in ("WARNINGS", "CRITICAL"):
        if kv.get(key, "").isdigit():
            lines.append(f'pitrisec_{key.lower()}{{tool="{tool}"}} {kv[key]}')
    try:
        ts = datetime.datetime.fromisoformat(kv["SCAN_DATE"]).timestamp()
        lines.append(f'pitrisec_scan_timestamp_seconds{{tool="{tool}"}} {int(ts)}')
    except (KeyError, ValueError):
        pass
    if tool == "lynis" and kv.get("HARDENING_INDEX", "").isdigit():
        lines.append(f"pitrisec_lynis_hardening_index {kv['HARDENING_INDEX']}")
lines.append(f'pitrisec_status{{tool="overall"}} {worst}')
tmp = OUT + ".tmp"
open(tmp, "w").write("\n".join(lines) + "\n")
os.replace(tmp, OUT)
