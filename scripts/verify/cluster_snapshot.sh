#!/usr/bin/env bash
# scripts/verify/cluster_snapshot.sh
#
# Point-in-time read-only snapshot of the cluster: node conditions, Argo sync/health,
# pod states, worked workload sets, disk, firing-alert LABELS, failed jobs, SMART wear
# attribution, halt state and GMGN feed freshness.
#
# Supersedes /tmp/state_snapshot.sh + /tmp/state_snapshot2.sh. The second was written
# because the first read a node's condition via conditions[-1] and mislabelled the
# column; this version prints every condition TYPE with its own STATUS explicitly.
#
# HOST: nexus (needs kubectl + /etc/rancher/k3s/k3s.yaml). cwd: anywhere.
# READ-ONLY: kubectl get/logs, one VictoriaMetrics query, plain file reads.
#            No apply / delete / exec / patch, and it writes nothing to disk.
# FAILURE LOOKS LIKE: node not Ready, an app not Synced/Healthy, a firing alert, or
#            an unparseable/absent input (which is INCONCLUSIVE, not clean).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$HERE/_lib.sh"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export VM="${VM:-http://10.43.33.250:8428}"
: "${TRADING_ROOT:=$HOME/Work/trading}"
export TRADING_ROOT

echo "verify/cluster_snapshot.sh  host=$(hostname)  cwd=$(pwd)  read-only"
echo "  kubeconfig=$KUBECONFIG  vm=$VM"
_hr

# ---------------------------------------------------------------- 1. nodes
section "1. NODES: every condition TYPE with its own STATUS"
"$PY" - <<'PY'
import _probe_lib as pl
r = pl.Report("nodes")
d, err = pl.kubectl_json("get", "nodes", "-o", "json")
if d is None:
    r.unknown("kubectl get nodes: %s" % err)
else:
    items = d.get("items", [])
    if not items:
        r.unknown("kubectl returned zero nodes")
    for n in items:
        name = n["metadata"]["name"]
        conds = {c["type"]: c["status"] for c in n["status"].get("conditions", [])}
        r.note("%-15s %s" % (name, "  ".join(
            "%s=%s" % (k, conds.get(k, "-"))
            for k in ("Ready", "MemoryPressure", "DiskPressure", "PIDPressure"))))
        if conds.get("Ready") != "True":
            r.bad("node %s Ready=%s" % (name, conds.get("Ready")))
        elif any(conds.get(k) == "True" for k in ("MemoryPressure", "DiskPressure", "PIDPressure")):
            r.bad("node %s under pressure: %s" % (name, conds))
        else:
            r.ok("node %s Ready, no pressure conditions" % name)
r.finish()
PY
bump_rc $?

# ---------------------------------------------------------------- 2. argo
section "2. ARGO APPLICATIONS: sync + health, exceptions named"
"$PY" - <<'PY'
import collections
import _probe_lib as pl
r = pl.Report("argo-apps")
d, err = pl.kubectl_json("-n", "argocd", "get", "applications", "-o", "json")
if d is None:
    r.unknown("kubectl get applications: %s" % err)
else:
    items = d.get("items", [])
    if not items:
        r.unknown("no Argo applications returned")
    sync, health, bad = collections.Counter(), collections.Counter(), []
    for a in items:
        st = a.get("status") or {}
        s = (st.get("sync") or {}).get("status", "?")
        h = (st.get("health") or {}).get("status", "?")
        sync[s] += 1
        health[h] += 1
        if s != "Synced" or h != "Healthy":
            bad.append("%s %s/%s" % (a["metadata"]["name"], s, h))
    r.note("apps=%d sync=%s health=%s" % (len(items), dict(sync), dict(health)))
    if bad:
        r.bad("apps not Synced+Healthy: %s" % bad)
    else:
        r.ok("all %d apps Synced + Healthy" % len(items))
r.finish()
PY
bump_rc $?

# ---------------------------------------------------------------- 3. pods
section "3. PODS not Running/Succeeded (with count)"
"$PY" - <<'PY'
import _probe_lib as pl
r = pl.Report("pods")
d, err = pl.kubectl_json("get", "pods", "-A", "-o", "json")
if d is None:
    r.unknown("kubectl get pods: %s" % err)
else:
    items = d.get("items", [])
    if not items:
        r.unknown("kubectl returned zero pods")
    odd = []
    for p in items:
        phase = (p.get("status") or {}).get("phase", "?")
        if phase not in ("Running", "Succeeded"):
            odd.append("%s/%s %s" % (p["metadata"]["namespace"],
                                     p["metadata"]["name"], phase))
    r.note("pods considered=%d" % len(items))
    if odd:
        for line in odd[:15]:
            r.note(line)
        r.bad("%d pod(s) not Running/Succeeded" % len(odd))
    else:
        r.ok("no pods outside Running/Succeeded")
r.finish()
PY
bump_rc $?

# ---------------------------------------------------------------- 4. workloads
section "4. TRADING + MINING pods"
"$PY" - <<'PY'
import _probe_lib as pl
r = pl.Report("workload-pods")
found = False
for ns, needle in (("trading", ("trading-daemon", "trading-mcp", "trading-alerts")),
                   ("mining", ())):
    d, err = pl.kubectl_json("-n", ns, "get", "pods", "-o", "json")
    if d is None:
        r.unknown("namespace %s: %s" % (ns, err))
        continue
    items = d.get("items", [])
    if not items:
        r.note("namespace %s: no pods" % ns)
        continue
    found = True
    for p in items:
        name = p["metadata"]["name"]
        if needle and not any(name.startswith(n) for n in needle):
            continue
        st = p.get("status") or {}
        ready = sum(1 for c in (st.get("containerStatuses") or []) if c.get("ready"))
        total = len(st.get("containerStatuses") or [])
        phase = st.get("phase")
        r.note("%-46s %s ready=%d/%d" % (name, phase, ready, total))
        if phase == "Succeeded":
            r.ok("pod %s Succeeded (completed job pod)" % name)
        elif phase == "Running" and ready == total and total:
            r.ok("pod %s Running and fully ready" % name)
        else:
            r.bad("pod %s phase=%s ready=%d/%d" % (name, phase, ready, total))
if not found:
    r.unknown("no trading/mining pods found at all")
r.finish()
PY
bump_rc $?

# ---------------------------------------------------------------- 5. disk
section "5. DISK (the device the disk alert names)"
DF="$(df -h /data/media 2>/dev/null | tail -n +2)"
if assert_nonempty "df /data/media" "$DF"; then
  note "$DF"
  pct="$(echo "$DF" | awk '{gsub(/%/,"",$5); print $5}')"
  check "$([ "${pct:-100}" -lt 90 ] && echo 0 || echo 1)" "/data/media use=${pct}% (<90% expected)"
fi

# ---------------------------------------------------------------- 6. alerts
section "6. FIRING ALERTS: alertname + the labels that say WHAT it is about"
"$PY" - <<'PY'
import collections
import _probe_lib as pl
r = pl.Report("firing-alerts")
res, err = pl.vm_query('ALERTS{alertstate="firing"}')
if res is None:
    r.unknown("VictoriaMetrics query failed: %s" % err)
else:
    r.note("firing series=%d" % len(res))
    if not res:
        r.ok("no firing alerts")
    else:
        grouped = collections.Counter()
        for item in res:
            m = item.get("metric", {})
            key = (m.get("alertname", "?"), m.get("instance", ""), m.get("device", ""),
                   m.get("job", ""), m.get("namespace", ""),
                   m.get("persistentvolumeclaim", ""))
            grouped[key] += 1
        for key, n in sorted(grouped.items()):
            name, inst, dev, job, ns, pvc = key
            extra = " ".join(x for x in (inst, dev, job, ns, pvc) if x)
            r.note("%-28s x%-2d %s" % (name, n, extra))
        # Watchdog fires by design (dead-man's switch); counting it would leave this
        # section permanently red, which trains the reader to ignore it. It is still
        # printed above, and every other alert name is counted as actionable.
        benign = {"Watchdog"}
        actionable = {k: n for k, n in grouped.items() if k[0] not in benign}
        if actionable:
            r.bad("%d actionable firing alert series across %d label(s) "
                  "(excluded as always-firing by design: %s)"
                  % (sum(actionable.values()), len(actionable), sorted(benign)))
        else:
            r.ok("nothing actionable firing (only always-firing %s)"
                 % ", ".join(sorted(benign)))
r.finish()
PY
bump_rc $?

# ---------------------------------------------------------------- 7. failures
section "7. FAILED jobs / Error pods (what actually broke)"
"$PY" - <<'PY'
import _probe_lib as pl
r = pl.Report("job-failures")
d, err = pl.kubectl_json("get", "jobs", "-A", "-o", "json")
if d is None:
    r.unknown("kubectl get jobs: %s" % err)
else:
    items = d.get("items", [])
    failed = []
    for j in items:
        st = j.get("status") or {}
        if st.get("failed"):
            failed.append("%s/%s failed=%s" % (j["metadata"]["namespace"],
                                               j["metadata"]["name"], st["failed"]))
    r.note("jobs=%d failed=%d" % (len(items), len(failed)))
    for line in failed[:8]:
        r.note(line)
    if failed:
        r.bad("%d job(s) with failures" % len(failed))
    else:
        r.ok("no job failures recorded")
r.finish()
PY
bump_rc $?

# ---------------------------------------------------------------- 8. smart
section "8. SMART wear: which device is it, really"
"$PY" - <<'PY'
import _probe_lib as pl
r = pl.Report("smart-wear")
res, err = pl.vm_query('ALERTS{alertname="SmartWearHigh",alertstate="firing"}')
if res is None:
    r.unknown("VictoriaMetrics query failed: %s" % err)
elif not res:
    r.ok("no SmartWearHigh firing")
else:
    for item in res:
        m = item.get("metric", {})
        r.note({k: v for k, v in m.items()
                if k in ("instance", "device", "model", "serial")})
    r.bad("SmartWearHigh firing on %d series" % len(res))
r.finish()
PY
bump_rc $?

# ---------------------------------------------------------------- 9. trading state
section "9. TRADING STATE: halt/KILL + GMGN feed freshness (field names printed)"
"$PY" - <<'PY'
import os
import statistics
import _probe_lib as pl
r = pl.Report("trading-state")
root = os.environ.get("TRADING_ROOT", os.path.expanduser("~/Work/trading"))

brk, err = pl.read_json(os.path.join(root, "data/breakers_state.json"))
if brk is None:
    r.unknown("breakers_state.json: %s" % err)
else:
    r.note("breakers_state keys: %s" % sorted(brk.keys()))
    r.note("halted=%s reason=%s" % (brk.get("halted"), str(brk.get("reason"))[:100]))
    if brk.get("halted"):
        r.bad("breaker HALTED")
    else:
        r.ok("breaker not halted")

kill = os.path.join(root, "data/KILL")
if os.path.exists(kill):
    r.bad("KILL switch file present at %s" % kill)
else:
    r.ok("no KILL switch file present")

for name in ("gmgn_flow.jsonl", "gmgn_sec.jsonl", "gmgn_track.jsonl", "gmgn_portfolio.jsonl"):
    path = os.path.join(root, "data", name)
    rows, note = pl.jsonl_rows(path)
    if rows is None or not rows:
        r.unknown("%s: %s (%s)" % (name, "absent" if rows is None else "no rows", note))
        continue
    row = rows[-1]
    field, val = pl.newest_ts(row)
    if field is None:
        r.unknown("%s: no timestamp field among %s" % (name, sorted(row.keys())))
        continue
    age = pl.age_min(val)
    stamps = sorted(v for v in (pl.newest_ts(x)[1] for x in rows) if v)
    gaps = [(b - a) / 60.0 for a, b in zip(stamps, stamps[1:])][-20:]
    if len(stamps) >= 5 and gaps:
        median = statistics.median(gaps)
        peak = max(gaps)
        threshold = 60.0 if median < 5 else max(3 * median, peak)
        r.note("%-24s rows=%-6d ts_field=%s age=%.1f min  gap_min(med/peak)=%.1f/%.1f  "
               "threshold=%.1f  fields=%s"
               % (name, len(rows), field, age, median, peak, threshold,
                  ",".join(sorted(row.keys()))[:70]))
        if age > threshold:
            r.bad("%s stale (%.1f min vs %.1f min derived from its own cadence)"
                  % (name, age, threshold))
        else:
            r.ok("%s fresh (%.1f min, threshold %.1f min derived from its own cadence)"
                 % (name, age, threshold))
    else:
        # No statistically meaningful cadence from a handful of rows; observe, do not assert.
        r.note("%-24s rows=%-6d ts_field=%s age=%.1f min  observed gaps=%s  TOO FEW ROWS "
               "to derive a cadence — observed, not asserted  fields=%s"
               % (name, len(rows), field, age,
                  [round(g, 1) for g in gaps] or "n/a", ",".join(sorted(row.keys()))[:60]))
        r.note("   (sparse artifact: judged by observation only, no pass/fail claimed)")

shad, note = pl.jsonl_rows(os.path.join(root, "data/auto_release_shadow.jsonl"))
if shad:
    row = shad[-1]
    r.note("auto_release_shadow rows=%d fields=%s" % (len(shad), ",".join(sorted(row.keys()))))
    r.note("  latest decision=%s enforce=%s reason=%s"
           % (row.get("decision"), row.get("enforce"), str(row.get("reason"))[:100]))
else:
    r.unknown("auto_release_shadow.jsonl unreadable/empty (%s)" % note)
r.finish()
PY
bump_rc $?

finish
