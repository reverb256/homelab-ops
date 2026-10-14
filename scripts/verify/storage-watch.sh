#!/usr/bin/env bash
# storage-watch v4 — anomaly-only watchdog for the nexus storage operation.
# SILENT when healthy. Informational lines exit 0; only real anomalies exit non-zero.
#
# v1 bug: treated `verify.done` (the *verification* pass) as "prune complete" -> announced
#         success at the unchanged baseline.
# v2 bug: no per-command bound -> HUNG under prune load.
# v3 bug: `timeout` does NOT bound a process blocked in D-state (uninterruptible IO), so one
#         `df` on the damaged volume hung the whole watchdog. A D-state process cannot be
#         killed by timeout; only its IO returning releases it.
# v4 rule: NEVER touch /data/media. Judge the operation by IO-free signals: D-state count,
#          load, cluster readiness, the deletion ledger's own progress, device state.
set +e
TO=${STORAGE_WATCH_TIMEOUT:-10}
STATE=${STORAGE_WATCH_STATE:-/home/j_kro/.cache/storage-watch.state}
LEDGER=${STORAGE_WATCH_LEDGER:-/home/j_kro/prune-20260923/ledger.jsonl}
mkdir -p "$(dirname "$STATE")" 2>/dev/null
ALERTS=(); INFO=()

reported=""
[ -f "$STATE" ] && reported=$(awk -F= '/^reported=/{print $2}' "$STATE")

# 1. IO wedge: D-state piling up is the precursor to kubelet death (measured: 21 at load 98).
dstate=$(timeout "$TO" sh -c "ps -eo stat | grep -c '^D'" 2>/dev/null)
[ -n "$dstate" ] && [ "$dstate" -gt 15 ] && ALERTS+=("IO wedge: ${dstate} processes in D-state (uninterruptible IO)")

# 2. Load.
load1=$(timeout "$TO" cut -d' ' -f1 /proc/loadavg 2>/dev/null)
loadint=${load1%%.*}
[ -n "$loadint" ] && [ "$loadint" -gt 60 ] && ALERTS+=("load average ${load1} - nexus is saturated")

# 3. Cluster readiness - cheap, and the thing that actually breaks.
#    Report WHY it failed. k3s rewrites /etc/rancher/k3s/k3s.yaml as 0600 root:root on
#    every start, and `k3s kubectl` then dies with
#      error loading config file "...": open ...: permission denied
#    That is a credential-mode problem, NOT a cluster outage — but this probe used to
#    report it as "cluster unreachable from nexus" (2026-10-14 16:00/16:30 runs, while
#    the API answered in 0.1s), which sent the triage hunting a nonexistent outage.
#    STORAGE_WATCH_KUBECONFIG exists so the message can be proven to name the reason.
_kc=${STORAGE_WATCH_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
_k3s_err=$(timeout 25 k3s kubectl --kubeconfig="$_kc" get nodes --request-timeout=20s 2>&1 >/dev/null)
_k3s_rc=$?
if [ "$_k3s_rc" -ne 0 ]; then
  # Prefer the specific cause (head -1: one kubectl line can match twice, and the alert
  # must stay single-line); the generic 'error loading config file' only names a class.
  _why=$(printf "%s\n" "$_k3s_err" | grep -m1 -oE "permission denied|no such file or directory|connection refused|refused|timed out|Timeout|no route to host|EOF" | head -1)
  [ -n "$_why" ] || _why=$(printf "%s\n" "$_k3s_err" | grep -m1 -oE "error loading config file[^:]*" | head -1)
  ALERTS+=("k3s API not answering - cluster unreachable from nexus (rc=$_k3s_rc kubeconfig=$_kc: ${_why:-no output})")
fi

# 4. Prune progress, from the deletion ledger's own mtime (no volume IO).
if [ -f "$LEDGER" ]; then
  age_min=$(( ( $(date +%s) - $(stat -c %Y "$LEDGER") ) / 60 ))
  rows=$(timeout "$TO" wc -l < "$LEDGER" 2>/dev/null | tr -dc '0-9')
  [ -n "$rows" ] && [ "$rows" -gt 0 ] && [ "$reported" != "yes" ] && {
    INFO+=("prune ledger has ${rows} recorded deletions (last write ${age_min} min ago) - see ${LEDGER}")
    reported=yes
  }
  if [ "$age_min" -gt 30 ]; then
    # A ledger idle with a terminal status (run-verified|run-complete) is a FINISHED
    # run: suppress. Do NOT use `|| echo 0` with grep -c — grep -c prints "0" AND
    # exits 1 on no match, so that idiom yields "0\n0" and [ -eq ] errors out, which
    # silently kills the alert in the very case it must fire. An empty read (timeout)
    # also reads as 0 -> alert fires, fail-safe.
    _ledger_terminal=$(timeout "$TO" grep -c -E "status.*(run-verified|run-complete)" "$LEDGER" 2>/dev/null)
    if [ "${_ledger_terminal:-0}" -eq 0 ]; then
      ALERTS+=("prune ledger idle ${age_min} min (${rows:-?} rows) - stalled, or finished: verify before assuming either")
    fi
  fi
fi

# 5. The cancelled migration must not be running.
timeout "$TO" pgrep -f "nvme1-migrat[e]" >/dev/null 2>&1 && ALERTS+=("CANCELLED migration relaunched - owner decision is cancel")

# 6. The 96%-worn Kingston stays retired.
timeout "$TO" findmnt -rn -S /dev/nvme1n1 >/dev/null 2>&1 && ALERTS+=("worn Kingston mounted again - it is retired")

printf 'reported=%s\n' "$reported" > "$STATE" 2>/dev/null

if [ ${#INFO[@]} -gt 0 ]; then
  echo "NEXUS STORAGE NOTICE ($(date -u +%FT%TZ))"
  for i in "${INFO[@]}"; do echo "  - $i"; done
fi
if [ ${#ALERTS[@]} -gt 0 ]; then
  echo "NEXUS STORAGE ALERT ($(date -u +%FT%TZ))"
  for a in "${ALERTS[@]}"; do echo "  - $a"; done
  exit 1
fi
exit 0
