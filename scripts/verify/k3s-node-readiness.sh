#!/usr/bin/env bash
# scripts/verify/k3s-node-readiness.sh — is every node Ready, and is any Job
# wedged in the pre-terminal FailureTarget state (which silently blocks its
# CronJob and is invisible to settled-only failure counting)?
#
# INCIDENT 2026-10-22 (this script is its regression check):
#   nexus k3s exited status=1 at 22:33 CDT 10-21 (etcd Range calls timing out at
#   5s, raft peer 10.1.1.140:2380 "no route to host"); nexus came back on its own
#   at 22:52. forge's k3s crash-looped against the dead apiserver and systemd gave
#   up at 22:37 with `Result=start-limit-hit`, `NRestarts=18`. A start-limit-hit
#   NEVER self-recovers, so forge sat NotReady for 3.6 hours (`Kubelet stopped
#   posting node status`). Two things then stayed silent:
#     * forge's pod trading-feed-forge-29877350 stuck Terminating, so the Job
#       carried condition FailureTarget=True and NO `Failed` condition. The
#       settled-only rule in scripts/monitor_snapshot.py counts terminal `Failed`
#       jobs, so the snapshot printed k8s_failing=0 while the lane was dark --
#       section B exists for exactly that blind spot.
#     * the CronJob's concurrencyPolicy=Forbid cannot create a run while that Job
#       is non-terminal, so the forge feed lane stopped at 22:58 and produced no
#       new failures to notice.
#   Recovery was `systemctl reset-failed k3s && systemctl start k3s` on forge;
#   node Ready 15s later, the wedged Job settled Failed, the next */10 tick ran.
#   Both halves above are asserted here so the next occurrence is not silent.
#
# Read-only: `kubectl get`. Nothing is started, deleted or restarted.
# Exit: 0 = OK, 1 = FAIL, 2 = INCONCLUSIVE.
# Overrides (so the gate can be proven to fire without touching the cluster):
#   K3S_NR_KUBECTL     kubeconfig-carrying kubectl command (default "k3s kubectl")
#   K3S_NR_NS          namespace for the wedged-Job section   (default trading)
#   K3S_NR_NOTREADY_S  grace before a NotReady node FAILs    (default 300)
#   K3S_NR_WEDGE_S     grace before a stuck Job FAILs        (default 1800)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$HERE/_lib.sh"

KC_CMD="${K3S_NR_KUBECTL:-k3s kubectl}"
NS="${K3S_NR_NS:-trading}"
NOTREADY_S="${K3S_NR_NOTREADY_S:-300}"
WEDGE_S="${K3S_NR_WEDGE_S:-1800}"

TMP_NODES="$(mktemp)"; TMP_JOBS="$(mktemp)"
trap 'rm -f "$TMP_NODES" "$TMP_JOBS"' EXIT

echo "k3s-node-readiness.sh  host=$(hostname)  $(date '+%Y-%m-%d %H:%M:%S%z')"

# ---------------------------------------------------------------- A. node Ready
section "A. every node posts Ready"
# shellcheck disable=SC2086
$KC_CMD get nodes -o json >"$TMP_NODES" 2>&1
if ! assert_nonempty "kubectl get nodes" "$(head -c 400 "$TMP_NODES")"; then
  note "cannot list nodes — is the API reachable? (see the text above)"
  finish
fi
if ! head -c 1 "$TMP_NODES" | grep -q '{'; then
  inconclusive "kubectl get nodes did not return JSON: $(head -2 "$TMP_NODES" | tr '\n' ' ')"
  finish
fi

node_report="$("$PY" - "$NOTREADY_S" "$TMP_NODES" <<'PYEOF'
import json, sys, time
from datetime import datetime, timezone
grace = float(sys.argv[1])
path = sys.argv[2]
now = time.time()

def age_of(ts):
    if not ts:
        return None
    try:
        return now - datetime.strptime(ts.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z").timestamp()
    except Exception:
        return None

d = json.load(open(path))
bad, names = [], []
for n in d.get("items", []):
    name = n["metadata"]["name"]
    names.append(name)
    ready = None
    for c in (n.get("status", {}).get("conditions") or []):
        if c.get("type") == "Ready":
            ready = c
    if ready is None:
        bad.append(f"{name}: no Ready condition at all")
        continue
    if ready.get("status") == "True":
        print(f"  [ok] {name}: Ready")
        continue
    age = age_of(ready.get("lastTransitionTime")) or age_of(ready.get("lastHeartbeatTime"))
    if age is not None and age < grace:
        print(f"  [ok] {name}: Ready={ready.get('status')} for {age:.0f}s (inside {grace:.0f}s grace)")
    else:
        a = f"{age/60:.0f}m" if age is not None else "age-unknown"
        bad.append(f"{name}: Ready={ready.get('status')} ({ready.get('reason')}) for {a}")
print("  nodes: " + (", ".join(names) if names else "NONE"))
for b in bad:
    print("detail: " + b)
print("VERDICT: " + ("FAILED" if bad else "HELD"))
PYEOF
)"

printf '%s\n' "$node_report" | grep -E '^(  \[ok\]|  nodes:)'
note "grace ${NOTREADY_S}s"
if printf '%s\n' "$node_report" | grep -qx 'VERDICT: HELD'; then
  check 0 "all node(s) post Ready"
else
  printf '%s\n' "$node_report" | sed -n 's/^detail: /   /p'
  check 1 "a node is NotReady past the ${NOTREADY_S}s grace — kubelet stopped posting status"
fi

# ------------------------------------------- B. Jobs stuck before terminal state
section "B. no Job wedged in FailureTarget (ns/$NS)"
# shellcheck disable=SC2086
$KC_CMD -n "$NS" get jobs -o json >"$TMP_JOBS" 2>&1
if ! assert_nonempty "kubectl -n $NS get jobs" "$(head -c 400 "$TMP_JOBS")"; then
  note "cannot list jobs in $NS"
elif ! head -c 1 "$TMP_JOBS" | grep -q '{'; then
  inconclusive "kubectl -n $NS get jobs did not return JSON: $(head -2 "$TMP_JOBS" | tr '\n' ' ')"
else
  wedge_report="$("$PY" - "$WEDGE_S" "$TMP_JOBS" <<'PYEOF'
import json, sys, time
from datetime import datetime
grace = float(sys.argv[1])
path = sys.argv[2]
now = time.time()

def age_of(ts):
    if not ts:
        return None
    try:
        return now - datetime.strptime(ts.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z").timestamp()
    except Exception:
        return None

d = json.load(open(path))
wedged, in_grace, seen = [], [], 0
for j in d.get("items", []):
    st = j.get("status", {}) or {}
    conds = {c.get("type"): c for c in (st.get("conditions") or [])}
    name = j["metadata"]["name"]
    seen += 1
    if (conds.get("Complete") or {}).get("status") == "True" or (conds.get("Failed") or {}).get("status") == "True":
        continue
    ft = conds.get("FailureTarget")
    if ft and ft.get("status") == "True":
        age = age_of(ft.get("lastTransitionTime")) or age_of(st.get("startTime"))
        if age is not None and age > grace:
            wedged.append(f"{name}: FailureTarget for {age/60:.0f}m, never settled to Failed "
                          f"(blocks its CronJob; invisible to settled-only failure counting)")
        else:
            in_grace.append(f"{name}: FailureTarget for {(age or 0)/60:.0f}m (inside grace)")
        continue
    deadline = (j.get("spec") or {}).get("activeDeadlineSeconds")
    started = age_of(st.get("startTime"))
    if st.get("active") or (st.get("terminating") or 0) > 0:
        if deadline and started is not None and started > deadline * 2:
            wedged.append(f"{name}: active/terminating {started/60:.0f}m with no terminal condition "
                          f"(activeDeadlineSeconds={deadline})")
        else:
            in_grace.append(f"{name}: active {(started or 0)/60:.0f}m")
print(f"  jobs seen: {seen}")
for a in (in_grace + ["(no in-flight job)"] if not in_grace else in_grace)[:4]:
    print("  [ok] " + a)
for w in wedged:
    print("detail: " + w)
print("VERDICT: " + ("FAILED" if wedged else "HELD"))
PYEOF
)"
  printf '%s\n' "$wedge_report" | grep -E '^(  \[ok\]|  jobs seen:)'
  if printf '%s\n' "$wedge_report" | grep -qx 'VERDICT: HELD'; then
    check 0 "no Job stuck pre-terminal beyond ${WEDGE_S}s"
  else
    printf '%s\n' "$wedge_report" | sed -n 's/^detail: /   /p'
    check 1 "a Job is wedged before its terminal state — its CronJob lane is blocked"
  fi
fi

finish
