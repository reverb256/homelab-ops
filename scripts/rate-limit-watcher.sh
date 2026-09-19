#!/bin/bash
# rate-limit-watcher.sh v2.1 — error-rate alerting + failing-job detection.
#
# v2.1 (2026-09-19) fixes found during install testing:
#  - matchers require explicit error tokens (HTTP 401 / Error code: 401 / ...) —
#    bare "401" matched session ids like …154017… (false positives)
#  - skips plugin-hook warning lines ("Hook '…" noise)
#  - email sent via python3 (notify-jkro.sh IS a python file — "bash <script>" broke it)
#  - email wrapped in try/except; state + heartbeat written BEFORE the send so a
#    hung/failed alert can never kill the watcher again
#  - 60m-window arms require activity in the 10m window too (still actively burning)
#
# Design (benchmarked against Google SRE multiwindow alerting + Alertmanager hygiene):
#  - rate-based windows (counts per 10m/60m from log timestamps)
#  - incident dedup: one alert per incident signature, re-alert at most every 4h
#  - failing-job check: any enabled cron job with failure_streak >= 3 alerts
#  - LLM-free alert path (plain email)
#  - silent on healthy runs (watchdog convention)
export HOME=/home/j_kro
export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$HOME/.local/share/mise/shims"
set -u

python3 - <<'PY'
import hashlib, json, os, re, subprocess, time
from datetime import datetime

HOME = os.path.expanduser("~")
STATE = f"{HOME}/.hermes/state/rate-limits"
LOG = f"{HOME}/.hermes/logs/agent.log"
os.makedirs(STATE, exist_ok=True)
now = time.time()
nowdt = datetime.now()

CLASS_PATTERNS = {
  "auth":    re.compile(r"AuthenticationError|Invalid credential|HTTP 401|Error code: 401|AuthError"),
  "quota":   re.compile(r"HTTP 402|Error code: 402|insufficient_quota|Add credits"),
  "rate":    re.compile(r"HTTP 429|Error code: 429|RateLimitError|fair-share"),
  "timeout": re.compile(r"TimeoutError|timed out|ETIMEDOUT|HTTP 408"),
}
TSRE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)")

try:
    lines = subprocess.run(["tail", "-n", "8000", LOG], capture_output=True, text=True, timeout=30).stdout.splitlines()
except Exception:
    lines = []

events = []  # (age_seconds, class, provider)
for ln in lines:
    m = TSRE.match(ln)
    if not m:
        continue
    try:
        dt = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
    except Exception:
        continue
    age = (nowdt - dt).total_seconds()
    if age > 3600 or age < 0:
        continue
    if "Hook '" in ln:
        continue
    if not re.search(r"ERROR|WARNING|failed", ln):
        continue
    for c, pat in CLASS_PATTERNS.items():
        if pat.search(ln):
            pm = re.search(r"provider=([A-Za-z0-9._-]+)", ln)
            events.append((age, c, pm.group(1) if pm else "unknown"))
            break

def summarize(maxage):
    tot = {c: 0 for c in CLASS_PATTERNS}
    byprov = {}
    for age, c, p in events:
        if age <= maxage:
            tot[c] += 1
            byprov.setdefault(p, {c2: 0 for c2 in CLASS_PATTERNS})[c] += 1
    return tot, byprov

t10, p10 = summarize(600)
t60, p60 = summarize(3600)

# failing cron jobs (enabled, streak >= 3)
jobs_err = []
try:
    d = json.load(open(f"{HOME}/.hermes/cron/jobs.json"))
    lst = d if isinstance(d, list) else d.get("jobs", d)
    lst = lst if isinstance(lst, list) else list(lst.values())
    for j in lst:
        if j.get("enabled") and (j.get("failure_streak") or 0) >= 3:
            jobs_err.append(f"{j.get('name')} (streak {j.get('failure_streak')}, last {j.get('last_status')})")
except Exception:
    pass

# incident triggers: short-window counts, or long-window counts that are STILL burning
# (the long arm requires at least one hit in the short window — multiwindow discipline).
RULES = [("auth", 3, 6), ("quota", 2, 4), ("rate", 12, 30), ("timeout", 5, 10)]
triggers = []
for c, a10, a60 in RULES:
    if t10[c] >= a10 or (t60[c] >= a60 and t10[c] > 0):
        triggers.append(f"{c}: {t10[c]}/10m, {t60[c]}/60m")
incident = bool(triggers) or bool(jobs_err)

# report file (keep last 48)
try:
    reps = sorted([f for f in os.listdir(STATE) if f.startswith("report-")])
    for old in reps[:-47]:
        os.remove(f"{STATE}/{old}")
except Exception:
    pass
ts = nowdt.strftime("%Y%m%d-%H%M%S")
top10 = sorted(p10.items(), key=lambda kv: -sum(kv[1].values()))[:5]
with open(f"{STATE}/report-{ts}.md", "w") as f:
    f.write(f"# rate-limit watch {ts}\n\ntriggers: {triggers or 'none'}\njobs: {jobs_err or 'none'}\n\n")
    f.write(f"10m: {t10}\n60m: {t60}\n\ntop providers (10m): {top10}\n")

# incident dedup state — written BEFORE the email so a failed send cannot lose state
stf = f"{STATE}/incident-state.json"
try:
    st = json.load(open(stf))
except Exception:
    st = {}
sig = hashlib.sha1(("|".join(sorted(triggers)) + ";" + "|".join(sorted(jobs_err))).encode()).hexdigest()[:12]
should_alert = incident and (st.get("sig") != sig or now - st.get("last_alert_at", 0) > 4 * 3600)

prev_open = bool(st.get("sig"))
if should_alert:
    st = {"sig": sig, "opened_at": st.get("opened_at", now), "last_alert_at": now}
elif incident:
    st["sig"] = sig
    st.setdefault("opened_at", now)
else:
    if prev_open:
        with open(f"{STATE}/digest.md", "a") as f:
            f.write(f"- {nowdt.isoformat(timespec='seconds')} incident RESOLVED (sig {st.get('sig')})\n")
    st = {}
json.dump(st, open(stf, "w"))

with open(f"{STATE}/digest.md", "a") as f:
    f.write(f"- {nowdt.isoformat(timespec='seconds')} 10m={t10} 60m={ {k: v for k, v in t60.items() if v} } incident={incident}\n")

json.dump({"ts": int(now), "incident": incident, "triggers": triggers, "jobs_err": jobs_err},
          open(f"{STATE}/last-run.json", "w"))
open(f"{STATE}/last-run", "w").write(str(int(now)))

# alert email LAST — never allowed to break the run
if should_alert:
    body = ["LLM provider incident detected by rate-limit-watcher v2.",
            "",
            f"Triggers: {triggers or '(none)'}",
            f"Job failures: {jobs_err or '(none)'}",
            f"10m counts: { {k: v for k, v in t10.items() if v} }",
            f"60m counts: { {k: v for k, v in t60.items() if v} }",
            f"Top providers (10m): {top10}",
            "",
            "Self-healing daemon runs every 10m (dry-run unless ~/.hermes/state/model-health/live exists).",
            f"Reports: {STATE}/report-*.md"]
    try:
        subprocess.run(["python3", f"{HOME}/.hermes/scripts/notify-jkro.sh",
                        "[watcher] LLM provider incident detected", "\n".join(body)],
                       capture_output=True, timeout=120)
    except Exception:
        with open(f"{STATE}/digest.md", "a") as f:
            f.write(f"- {nowdt.isoformat(timespec='seconds')} EMAIL SEND FAILED (timeout/error)\n")
    print("INCIDENT: " + "; ".join(triggers + jobs_err))
PY
