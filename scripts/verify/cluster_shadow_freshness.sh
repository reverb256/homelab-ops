#!/usr/bin/env bash
# scripts/verify/cluster_shadow_freshness.sh
#
# Is the cluster-shadow writer actually alive, and is its artifact fresh?
#
# This exists because a previous audit of exactly this question reported the shadow
# "7.6h stale" and implied a dead writer. That was WRONG, and the correction is the
# point of the script:
#
#   data/cluster_shadow.jsonl has NO `ts` field. It carries two clocks:
#     event_ts     — when the market event happened (lags by design: a forward-return
#                    shadow cannot record fwd30/fwd60 until the horizon has passed)
#     recorded_ts  — when the writer wrote the row (the writer's own clock)
#   A reader that guesses `ts`, or grabs event_ts, sees a 6-8h lag and calls the
#   writer dead. Read recorded_ts, and cross-check the heartbeat:
#     data/cluster_shadow_heartbeat.json {ts, cycle, owner, pid, interval_s}
#   A fresh heartbeat with an old artifact means "writer alive, sampling quiet",
#   which is a completely different statement from "stale".
#
# This script therefore prints every clock it finds, names which one it judged on, and
# reports writer liveness and artifact cadence as two separate verdicts.
# Supersedes /tmp/check_shadow_timers.sh.
#
# HOST: nexus (kubectl + ~/Work/trading). cwd: anywhere (TRADING_ROOT overrides).
# READ-ONLY: file reads + kubectl get only.
# FAILURE LOOKS LIKE: heartbeat absent/unparseable (INCONCLUSIVE), heartbeat older
#   than 2x interval_s or owner pod not Running (FAIL), or no recognised timestamp
#   field at all (INCONCLUSIVE — schema drift, not a clean result).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$HERE/_lib.sh"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
: "${TRADING_ROOT:=$HOME/Work/trading}"
export TRADING_ROOT

echo "verify/cluster_shadow_freshness.sh  host=$(hostname)  cwd=$(pwd)  read-only"
echo "  trading_root=$TRADING_ROOT"
if [ ! -d "$TRADING_ROOT" ]; then
  inconclusive "TRADING_ROOT=$TRADING_ROOT does not exist on $(hostname) — wrong host?"
  finish
fi
_hr

section "1. WRITER LIVENESS + ARTIFACT CLOCKS (every field printed, judgement labelled)"
"$PY" - <<'PY'
import os
import _probe_lib as pl
r = pl.Report("cluster-shadow")
root = os.environ.get("TRADING_ROOT", os.path.expanduser("~/Work/trading"))
now = pl.time.time()

# ---- artifact
path = os.path.join(root, "data/cluster_shadow.jsonl")
rows, note = pl.jsonl_rows(path)
if rows is None:
    r.unknown("cluster_shadow.jsonl: %s" % note)
elif not rows:
    r.unknown("cluster_shadow.jsonl: no parseable rows (%s)" % note)
else:
    last = rows[-1]
    r.note("cluster_shadow.jsonl rows=%d file_mtime=%s (%s bytes)%s"
           % (len(rows), pl.hhmm(os.path.getmtime(path)), os.path.getsize(path),
              " " + note if note else ""))
    r.note("last row fields: %s" % ", ".join(sorted(last.keys())))
    clocks = {k: last.get(k) for k in ("event_ts", "recorded_ts", "ts")}
    for key, val in clocks.items():
        if isinstance(val, (int, float)) and val:
            r.note("clock %-12s = %-12s (%s) age=%.1f min"
                   % (key, val, pl.hhmm(val), pl.age_min(val, now)))
        else:
            r.note("clock %-12s = ABSENT" % key)
    if not any(isinstance(v, (int, float)) and v for v in clocks.values()):
        r.unknown("no timestamp field of any kind on the last row — schema drift")
    elif not clocks.get("recorded_ts"):
        r.unknown("no recorded_ts on the last row; event_ts alone is NOT a freshness signal")
    else:
        r.note("judging artifact cadence on recorded_ts (the writer's own clock); "
               "event_ts is the EVENT clock and lags by design — reading it as staleness "
               "is exactly the error this script exists to prevent")

# ---- heartbeat (the writer's own liveness signal)
hb, herr = pl.read_json(os.path.join(root, "data/cluster_shadow_heartbeat.json"))
if hb is None:
    r.unknown("cluster_shadow_heartbeat.json: %s" % herr)
else:
    r.note("heartbeat fields: %s" % ", ".join(sorted(hb.keys())))
    r.note("heartbeat: ts=%s (%s) cycle=%s owner=%s pid=%s interval_s=%s"
           % (hb.get("ts"), pl.hhmm(hb.get("ts")), hb.get("cycle"),
              hb.get("owner"), hb.get("pid"), hb.get("interval_s")))
    interval = hb.get("interval_s")
    ts = hb.get("ts")
    if not isinstance(ts, (int, float)) or not ts:
        r.unknown("heartbeat has no numeric ts")
    elif not isinstance(interval, (int, float)) or not interval:
        r.unknown("heartbeat has no interval_s — cannot judge cadence")
    else:
        age = pl.age_min(ts, now)
        if age > 2 * (interval / 60.0):
            r.bad("WRITER STALE: heartbeat %.1f min old, interval %ss" % (age, interval))
        else:
            r.ok("writer ALIVE: heartbeat %.1f min old, interval %ss, cycle %s"
                 % (age, interval, hb.get("cycle")))
        # artifact cadence, reported separately so it cannot be confused with liveness
        if clocks.get("recorded_ts"):
            gap = pl.age_min(last["recorded_ts"], now)
            r.note("artifact cadence: newest recorded_ts is %.1f min old "
                   "(%.1f write intervals); a live heartbeat with a quiet artifact means "
                   "'writer alive, sampling quiet', not 'stale'"
                   % (gap, gap / (interval / 60.0) if interval else 0))
    # owner pod must be Running if we can see the cluster
    owner = str(hb.get("owner") or "")
    if not owner:
        r.unknown("heartbeat has no owner — cannot confirm the owning pod is Running")
    else:
        d, err = pl.kubectl_json("-n", "trading", "get", "pods", "-o", "json")
        if d is None:
            r.unknown("kubectl get pods: %s" % err)
        else:
            hit = [p for p in d.get("items", []) if p["metadata"]["name"] == owner]
            if not hit:
                r.bad("owner pod %s not present in namespace trading" % owner)
            else:
                pod = hit[0]
                phase = (pod.get("status") or {}).get("phase")
                if phase == "Running":
                    r.ok("owner pod %s Running" % owner)
                else:
                    r.bad("owner pod %s phase=%s" % (owner, phase))
r.finish()
PY
bump_rc $?

section "2. HOST TIMER INVENTORY — where does the schedule actually live?"
"$PY" - <<'PY'
import socket
import _probe_lib as pl
r = pl.Report("host-timers")
HOSTS = ["nexus", "forge", "sentry"]
here = socket.gethostname()
checked = 0
for host in HOSTS:
    if host == here:
        import subprocess
        out = subprocess.run(["systemctl", "list-timers", "--all"], capture_output=True,
                             text=True).stdout
        checked += 1
    else:
        import subprocess
        proc = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                               host, "systemctl list-timers --all 2>/dev/null"],
                              capture_output=True, text=True)
        if proc.returncode != 0 or not proc.stdout.strip():
            r.unknown("%s: could not read systemctl list-timers (%s)"
                      % (host, proc.stderr.strip()[:80] or "empty"))
            continue
        out = proc.stdout
        checked += 1
    hits = [ln.strip() for ln in out.splitlines()
            if any(w in ln.lower() for w in ("trading", "halt", "alert", "shadow"))]
    r.note("%s: %d matching timer line(s)" % (host, len(hits)))
    for line in hits:
        r.note("   %s" % line)
    if host == here and not hits:
        r.ok("%s: no trading/halt/alert/shadow host timers" % host)
if not checked:
    r.unknown("no host was reachable to inventory timers")
else:
    r.ok("inventoried timers on %d host(s)" % checked)
r.finish()
PY
bump_rc $?

finish
