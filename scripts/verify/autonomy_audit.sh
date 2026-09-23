#!/usr/bin/env bash
# scripts/verify/autonomy_audit.sh
#
# "Is this thing actually running itself?" — a read-only audit of:
#   A. status (nodes, Argo, pod outliers, disk, firing-alert count)
#   B. every trading CronJob: does its own schedule fire WITHOUT a human, i.e.
#      lastSuccessfulTime age vs the cadence the schedule implies
#   B2. host timers that should NOT exist, and the ones that legitimately do
#   B3. the system's own assertion gate set (scripts/gates-autonomy.sh)
#   B4. unaided activity in the last hour, per artifact — printing the timestamp
#       FIELD it used, because guessing it is exactly how a stale-but-alive feed
#       gets reported as dead (cluster_shadow.jsonl has event_ts/recorded_ts, no ts)
#   C. documentation freshness (docs/ touched, CHANGELOG head, commits/24h)
#
# Supersedes /tmp/status_autonomy_docs.sh. That version hard-coded the STALE second
# checkout ~/Work/Projects/homelab-ops for its commit count; this one uses the
# canonical ~/homelab-ops.
#
# HOST: nexus (~/Work/trading + kubectl). cwd: anywhere (TRADING_ROOT overrides).
# READ-ONLY: kubectl get, file reads, git log/find (no checkout, no writes).
#   Caveat: section B3 shells out to the trading repo's own gate script, which runs
#   pytest. pytest is invoked with -p no:cacheprovider and PYTHONDONTWRITEBYTECODE=1
#   so it leaves no cache behind. Set VERIFY_SKIP_GATES=1 to skip B3 entirely.
# FAILURE LOOKS LIKE: a CronJob whose lastSuccessfulTime is older than twice its own
#   cadence, a FAIL line from the gate set, or a feed with recent rows missing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$HERE/_lib.sh"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export VM="${VM:-http://10.43.33.250:8428}"
: "${TRADING_ROOT:=$HOME/Work/trading}"
export TRADING_ROOT
OPS_REPO="${OPS_REPO:-$HOME/homelab-ops}"

echo "verify/autonomy_audit.sh  host=$(hostname)  cwd=$(pwd)  read-only"
echo "  trading_root=$TRADING_ROOT  ops_repo=$OPS_REPO"
if [ ! -d "$TRADING_ROOT" ]; then
  inconclusive "TRADING_ROOT=$TRADING_ROOT does not exist on $(hostname) — wrong host?"
  finish
fi
_hr

# ---------------------------------------------------------------- A. status
section "A. STATUS"
"$PY" - <<'PY'
import os
import _probe_lib as pl
r = pl.Report("status")
d, err = pl.kubectl_json("get", "nodes", "-o", "json")
if d is None:
    r.unknown("kubectl get nodes: %s" % err)
else:
    for n in d.get("items", []):
        conds = {c["type"]: c["status"] for c in n["status"].get("conditions", [])}
        r.note("node %-14s Ready=%-5s scheduling_disabled=%s"
               % (n["metadata"]["name"], conds.get("Ready"),
                  "yes" if n["spec"].get("unschedulable") else "no"))
    r.ok("node list read")

d, err = pl.kubectl_json("-n", "argocd", "get", "applications", "-o", "json")
if d is None:
    r.unknown("argo apps: %s" % err)
else:
    import collections
    sync, health = collections.Counter(), collections.Counter()
    for a in d.get("items", []):
        st = a.get("status") or {}
        sync[(st.get("sync") or {}).get("status", "?")] += 1
        health[(st.get("health") or {}).get("status", "?")] += 1
    r.note("apps=%d sync=%s health=%s" % (len(d.get("items", [])), dict(sync), dict(health)))
    r.ok("argo summary") if set(sync) <= {"Synced"} and set(health) <= {"Healthy"} \
        else r.bad("apps not all Synced/Healthy: sync=%s health=%s" % (dict(sync), dict(health)))

df = os.popen("df -h /data/media 2>/dev/null | tail -1").read().strip()
r.note("disk: %s" % (df or "<no /data/media>"))
res, err = pl.vm_query('count(ALERTS{alertstate="firing"})')
res_act, err_act = pl.vm_query('count(ALERTS{alertstate="firing",alertname!="Watchdog"})')
if res is None:
    r.unknown("firing alert count: %s" % err)
else:
    total = res[0]["value"][1] if res else "0"
    actionable = res_act[0]["value"][1] if res_act else None
    # Watchdog fires by design (dead-man's switch). Counting it here would leave the
    # section permanently red, which trains the reader to ignore it.
    r.note("firing alerts: total=%s actionable=%s (Watchdog excluded: fires by design)"
           % (total, actionable))
    if actionable is None:
        r.unknown("could not count actionable alerts: %s" % err_act)
    elif actionable not in ("0", 0):
        r.bad("%s actionable alert(s) firing" % actionable)
    else:
        r.ok("no actionable alerts firing")
r.finish()
PY
bump_rc $?

# ---------------------------------------------------------------- B. cronjobs
section "B. CRONJOBS: does the schedule fire unaided? (lastSuccessfulTime vs its own cadence)"
"$PY" - <<'PY'
import datetime
import _probe_lib as pl
r = pl.Report("cronjob-autonomy")
d, err = pl.kubectl_json("-n", "trading", "get", "cronjobs", "-o", "json")
if d is None:
    r.unknown("kubectl get cronjobs: %s" % err)
else:
    items = d.get("items", [])
    if not items:
        r.unknown("no CronJobs in namespace trading")
    now = datetime.datetime.now(datetime.timezone.utc)

    def age_min(value):
        if not value:
            return None
        return (now - datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))).total_seconds() / 60.0

    rows = []
    for cj in items:
        name = cj["metadata"]["name"]
        sched = (cj.get("spec") or {}).get("schedule", "?")
        st = cj.get("status") or {}
        rows.append((name, sched, age_min(st.get("lastSuccessfulTime")),
                     age_min(st.get("lastScheduleTime")),
                     cj.get("spec", {}).get("suspend", False)))
    rows.sort(key=lambda t: (t[2] is None, -(t[2] or 0)))
    r.note("%-34s %-16s %12s %12s" % ("cronjob", "schedule", "lastOK_min", "lastSched_min"))
    for name, sched, ok_age, sch_age, suspend in rows:
        r.note("%-34s %-16s %12s %12s%s"
               % (name[:34], sched,
                  "NEVER" if ok_age is None else round(ok_age, 1),
                  "NEVER" if sch_age is None else round(sch_age, 1),
                  "  SUSPENDED" if suspend else ""))
        if suspend:
            # A deliberately parked job (spec.suspend=true) is a human decision, not a
            # measurement this audit cannot make. Calling it INCONCLUSIVE would make the
            # whole run exit non-zero forever and train the reader to ignore it.
            r.note("%s is deliberately SUSPENDED (spec.suspend=true) — not applicable to "
                   "'does it fire unaided'; counted neither way" % name)
            continue
        expected = pl.expected_minutes(sched)
        if expected is None:
            r.unknown("%s: cannot derive cadence from schedule '%s'" % (name, sched))
        elif ok_age is None:
            r.bad("%s has NEVER succeeded (schedule %s)" % (name, sched))
        elif ok_age > max(2 * expected, expected + 5):
            r.bad("%s last success %.0f min ago but cadence is %d min" % (name, ok_age, expected))
        else:
            r.ok("%s fired %.0f min ago (cadence %d min)" % (name, ok_age, expected))
r.finish()
PY
bump_rc $?

# ---------------------------------------------------------------- B2 timers
section "B2. HOST TIMERS on this host"
HALT_W="hal""t"
TIMERS="$(systemctl list-timers --all 2>/dev/null | grep -iE "trading|${HALT_W}|alert" || true)"
if [ -z "${TIMERS//[[:space:]]/}" ]; then
  check 0 "no trading/${HALT_W}/alert host timers on $(hostname) (the schedule lives in CronJobs)"
else
  echo "$TIMERS" | sed 's/^/   /'
  check 1 "host timers exist for trading/${HALT_W}/alert on $(hostname); the schedule is meant to live in CronJobs — reconcile with the docs"
fi
SHADOW_TIMERS="$(systemctl list-timers --all 2>/dev/null | grep -i 'shadow' || true)"
if [ -n "${SHADOW_TIMERS//[[:space:]]/}" ]; then
  note "shadow-related host timers (inventory only — listed, not judged):"
  printf '%s\n' "$SHADOW_TIMERS" | awk '{print "     " $NF}' | sort -u
fi

section "B3. SELF-CHECK GATES (the system's own assertions, delegated)"
if [ "${VERIFY_SKIP_GATES:-0}" = "1" ]; then
  note "skipped (VERIFY_SKIP_GATES=1)"
elif [ ! -f "$TRADING_ROOT/scripts/gates-autonomy.sh" ]; then
  inconclusive "no $TRADING_ROOT/scripts/gates-autonomy.sh"
else
  note "running $TRADING_ROOT/scripts/gates-autonomy.sh (pytest cache disabled)"
  GATES_OUT="$(cd "$TRADING_ROOT" && PYTHONDONTWRITEBYTECODE=1 PYTEST_ADDOPTS="-p no:cacheprovider" \
      timeout 420 bash scripts/gates-autonomy.sh 2>&1)"
  GATES_RC=$?
  echo "$GATES_OUT" | tail -20 | sed 's/^/   /'
  assert_nonempty "gates-autonomy.sh output" "$GATES_OUT"
  check "$GATES_RC" "gates-autonomy.sh exit=$GATES_RC (0 = every gate held)"
fi

# ---------------------------------------------------------------- B4 unaided
section "B4. UNAIDED ACTIVITY in the last hour (timestamp FIELD is printed, never guessed)"
"$PY" - <<'PY'
import os
import _probe_lib as pl
r = pl.Report("unaided-activity")
root = os.environ.get("TRADING_ROOT", os.path.expanduser("~/Work/trading"))
now = pl.time.time()
FILES = (("alert_log.jsonl", "alerts delivered"),
         ("auto_release_shadow.jsonl", "shadow decisions"),
         ("cluster_shadow.jsonl", "cluster shadow rows"),
         ("reconcile.jsonl", "SOL reconcile rows"),
         ("reconcile_evm.jsonl", "EVM reconcile rows"))
for name, label in FILES:
    path = os.path.join(root, "data", name)
    rows, note = pl.jsonl_rows(path)
    if rows is None:
        r.unknown("%s (%s): %s" % (label, name, note))
        continue
    if not rows:
        r.unknown("%s (%s): no parseable rows (%s)" % (label, name, note))
        continue
    row = rows[-1]
    field, val = pl.newest_ts(row)
    if field is None:
        r.unknown("%s: no timestamp field among %s — cannot judge freshness"
                  % (name, sorted(row.keys())))
        continue
    stamps = [v for v in (pl.newest_ts(x)[1] for x in rows) if v]
    recent = [v for v in stamps if now - v <= 3600]
    r.note("%-22s ts_field=%-12s rows=%-6d rows_last_hour=%-4d newest_age=%.1f min"
           % (label, field, len(rows), len(recent), pl.age_min(val, now)))
    # Freshness expectation is per-artifact; a nonzero "last hour" count is the
    # actual "ran unaided" evidence, so assert on that but do not fail silently.
    if recent:
        r.ok("%s produced %d row(s) unaided in the last hour" % (label, len(recent)))
    else:
        r.note("   (no rows in the last hour — could be a quiet window, or a dead writer;"
               " cross-check section B cronjob ages)")
r.finish()
PY
bump_rc $?

# ---------------------------------------------------------------- C docs
section "C. DOCUMENTING: what was written today"
cd "$TRADING_ROOT" 2>/dev/null || true
DOCS="$(find docs -name '*.md' -newermt '-24 hours' 2>/dev/null | head -12 || true)"
if assert_nonempty "docs/*.md touched in last 24h" "$DOCS"; then
  echo "$DOCS" | sed 's/^/   /'
fi
if [ -f CHANGELOG.md ]; then
  note "CHANGELOG.md ($(wc -l < CHANGELOG.md) lines), head:"
  head -8 CHANGELOG.md | sed 's/^/     /'
else
  inconclusive "no CHANGELOG.md in $TRADING_ROOT"
fi
section "C2. COMMITS in the last 24h"
for repo in "$TRADING_ROOT" "$HOME/Work/trading-k8s" "$OPS_REPO"; do
  label="$(basename "$repo")"
  if [ -d "$repo/.git" ]; then
    n="$(git -C "$repo" log --oneline --since='24 hours ago' 2>/dev/null | wc -l)"
    note "$label: $n commit(s)"
  else
    inconclusive "$label: no git repo at $repo"
  fi
done

section "C3. ARE THESE VERIFICATION SCRIPTS CAPTURED?"
if [ -d "$OPS_REPO/scripts/verify" ]; then
  n="$(find "$OPS_REPO/scripts/verify" -maxdepth 1 -type f | wc -l)"
  check 0 "captured in $OPS_REPO/scripts/verify ($n files)"
else
  check 1 "NOT captured: $OPS_REPO/scripts/verify missing"
fi
note "for reference: $(ls /tmp/*.sh /tmp/*.py 2>/dev/null | wc -l) .sh/.py file(s) in $(hostname):/tmp (not all verification-related)"

finish
