#!/bin/bash
# watcher-watchdog.sh — dead-man switch for the self-healing watchers themselves.
#
# The 2026-09-19 incident: the MAM interview was missed because the self-healing
# stack had silently stopped being scheduled. Nothing watched the watchers.
# This job alerts on ABSENCE: stale last-run stamps or missing/disabled cron jobs.
# Mechanics per cron-monitoring practice: heartbeat written only by the real run;
# grace = 3x interval; dedup re-alert every 6h; plain-email alert path.
# NOTE: notify-jkro.sh is a PYTHON script — call it via python3, never via bash.
export HOME=/home/j_kro
export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$HOME/.local/share/mise/shims"
set -u

python3 - <<'PY'
import json, os, subprocess, time

HOME = os.path.expanduser("~")
S = f"{HOME}/.hermes/state"
now = time.time()
alerts = []

CHECKS = [  # (label, stamp file, grace seconds, cron job name to verify)
    ("model-health-daemon", f"{S}/model-health/last-run", 35 * 60, "model-health-daemon"),
    ("rate-limit-watcher", f"{S}/rate-limits/last-run", 50 * 60, "rate-limit-watcher"),
]

try:
    d = json.load(open(f"{HOME}/.hermes/cron/jobs.json"))
    lst = d if isinstance(d, list) else d.get("jobs", d)
    lst = lst if isinstance(lst, list) else list(lst.values())
    names = {j.get("name"): j for j in lst if j.get("name")}
except Exception:
    names = {}

for label, stamp, grace, jobname in CHECKS:
    j = names.get(jobname)
    if not j or not j.get("enabled"):
        alerts.append(f"{label}: CRON JOB MISSING OR DISABLED")
        continue
    try:
        last = int(open(stamp).read().strip())
    except Exception:
        last = 0
    if not last:
        alerts.append(f"{label}: never ran (no heartbeat)")
    elif now - last > grace:
        alerts.append(f"{label}: STALE — last run {int((now - last) / 60)} min ago (grace {grace // 60}m)")

sd = f"{S}/watcher-watchdog"
os.makedirs(sd, exist_ok=True)
stf = f"{sd}/state.json"
try:
    st = json.load(open(stf))
except Exception:
    st = {}

sig = ";".join(sorted(a.split(":")[0] for a in alerts))
if alerts and (st.get("sig") != sig or now - st.get("last_alert_at", 0) > 6 * 3600):
    st = {"sig": sig, "last_alert_at": now}
    json.dump(st, open(stf, "w"))
    try:
        subprocess.run(["python3", f"{HOME}/.hermes/scripts/notify-jkro.sh",
                        "[watcher] self-healing stack ALERT",
                        "Watcher-watchdog: the provider-failure watchers are NOT healthy:\n\n  - " +
                        "\n  - ".join(alerts) +
                        "\n\nCheck: hermes cron list | grep -E 'model-health|rate-limit|watcher-watchdog'"],
                       capture_output=True, timeout=120)
    except Exception:
        pass
elif not alerts:
    json.dump({}, open(stf, "w"))
open(f"{sd}/last-run", "w").write(str(int(now)))

if alerts:
    print("WATCHDOG ALERT: " + " | ".join(alerts))
PY
