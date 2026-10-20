#!/usr/bin/env bash
# scripts/verify/alert-lane-live.sh
#
# Guards the 2026-10-02 alert-lane blackout (nexus, ~/Work/trading).
#
# What happened: the halt/reminder delivery lane (tools/halt_alerts.py -> the A2A peer
# gateway on port 9900) stopped authenticating. The last confirmed delivery in
# data/alert_log.jsonl is 2026-10-02 04:00 (`ok: true, status: 200`); every attempt since
# came back HTTP 403 / 429. By 2026-10-20 the queue held 10 halt reports + 1202 reminders
# ("parked"), oldest 18 days old -- and NOTHING in the sentinel's snapshot said so. The
# only line the sweep produced was `[WARN] jsonl over 100MB (archive due)` for
# data/alert_log.jsonl, i.e. the *symptom* (55k failed-delivery rows/day) reached us and
# the *cause* (no alert has been delivered for 18 days) did not.
#
# Root cause seen at the time (2026-10-20): the peer credential file
# data/halt_peer.env carries a bearer token that the gateway no longer recognises
# (`HTTP 403 {"code": -32052, "message": "peer 'nexus' not trusted"}`), while the token
# currently in ~/.hermes/.env A2A_PEER_TOKENS draws `401 unauthorized` -- i.e. the
# running gateway's captured A2A context predates the rotated tokens, and
# `a2a_agents.hermes-nexus` (the entry provision-peer-env.py renders from) is gone from
# config.yaml. Fixing it is a live gateway/credential change (hermes-gateway@nexus), not
# something a monitor run performs.
#
# So this script does NOT ask "did an alert fire" -- a quiet trading day legitimately
# sends nothing. It asks whether the lane can still DELIVER:
#   queue non-empty (undelivered reports/reminders)   -> FAIL (alerts are stuck)
#   attempts inside the window but no ok:true in it   -> FAIL (delivering nothing)
#   queue empty + a confirmed ok:true in the window   -> OK
#   queue empty + zero attempts in the window         -> OK (lane idle, nothing to send)
#   no last ok on record + attempts in the window     -> FAIL
#   files missing/unparseable                         -> INCONCLUSIVE (never "clean")
#
# EXPECTED RED while the queue is stuck: that red IS the finding (same contract as
# feed-path-live.sh); it clears when a delivery lands with `ok: true`.
#
# HOST: nexus (~/Work/trading). READ-ONLY: reads two data files, writes nothing, touches
#   no service -- in particular it does NOT restart the gateway or re-render the peer
#   credential, both of which need the service lock.
# Exit: 0 = OK, 1 = FAIL, 2 = INCONCLUSIVE.
# Overrides (so the gate can be proven to fire AND not to false-fire):
#   TRADING_ROOT ALERT_DEGRADED_FILE ALERT_LOG_FILE ALERT_MAX_AGE_S
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$HERE/_lib.sh"

: "${TRADING_ROOT:=$HOME/Work/trading}"
: "${ALERT_DEGRADED_FILE:=$TRADING_ROOT/data/alert_degraded.json}"
: "${ALERT_LOG_FILE:=$TRADING_ROOT/data/alert_log.jsonl}"
: "${ALERT_MAX_AGE_S:=86400}"

command -v "$PY" >/dev/null 2>&1 || { echo "INCONCLUSIVE: python not found (run on nexus)"; exit 2; }

echo "verify/alert-lane-live.sh  host=$(hostname)  read-only"
echo "  degraded=$ALERT_DEGRADED_FILE"
echo "  log=$ALERT_LOG_FILE  window=${ALERT_MAX_AGE_S}s"
_hr

# _json <file> <dotted.path> -> value, or MISSING / ERR
_json() {
  "$PY" - "$1" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as fh:
        doc = json.load(fh)
except Exception:
    print("ERR"); sys.exit(0)
cur = doc
for part in sys.argv[2].split("."):
    if not isinstance(cur, dict) or part not in cur:
        print("MISSING"); sys.exit(0)
    cur = cur[part]
print("true" if cur is True else "false" if cur is False else "null" if cur is None else cur)
PY
}

# _logstats <file> <window_s> -> "last_ok_ts attempts_in_window top_statuses"
_logstats() {
  "$PY" - "$1" "$2" <<'PY' 2>/dev/null
import collections, json, sys, time
path, window = sys.argv[1], int(sys.argv[2])
now = time.time()
cut = now - window
last_ok = 0
attempts = 0
statuses = collections.Counter()
try:
    with open(path, errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            ts = row.get("ts") or 0
            if row.get("ok") is True and ts > last_ok:
                last_ok = ts
            if ts >= cut:
                attempts += 1
                statuses[str(row.get("status"))[:44]] += 1
except Exception:
    print("ERR 0 0"); sys.exit(0)
top = " | ".join(f"{c}x {s or '(empty)'}" for s, c in statuses.most_common(3)) or "-"
print(f"{last_ok} {attempts} {top}")
PY
}

section "1. UNDELIVERED QUEUE (data/alert_degraded.json)"
if [ ! -f "$ALERT_DEGRADED_FILE" ]; then
  inconclusive "degraded-state file missing: $ALERT_DEGRADED_FILE — cannot prove the lane is delivering"
  finish
fi
reports="$(_json "$ALERT_DEGRADED_FILE" undelivered_reports)"
reminders="$(_json "$ALERT_DEGRADED_FILE" undelivered_reminders)"
parked="$(_json "$ALERT_DEGRADED_FILE" parked)"
oldest_min="$(_json "$ALERT_DEGRADED_FILE" oldest_age_min)"
last_error="$(_json "$ALERT_DEGRADED_FILE" last_error)"
deg_ts="$(_json "$ALERT_DEGRADED_FILE" updated_ts)"
if [ "$reports" = "ERR" ] || [ -z "$reports" ]; then
  inconclusive "degraded-state file unparseable: $ALERT_DEGRADED_FILE (schema drift, not a clean result)"
  finish
fi
note "undelivered reports=$reports reminders=$reminders parked=$parked oldest=${oldest_min}min"
note "last_error=$last_error (state written $(( $(date +%s) - ${deg_ts:-0} ))s ago)"
queued=0
[[ "$reports" =~ ^[0-9]+$ ]] && [ "$reports" -gt 0 ] && queued=$(( queued + reports ))
[[ "$reminders" =~ ^[0-9]+$ ]] && [ "$reminders" -gt 0 ] && queued=$(( queued + reminders ))
if [ "$queued" -gt 0 ]; then
  note "QUEUE: $queued message(s) waiting — the lane is not delivering"
else
  note "QUEUE: empty"
fi

section "2. DELIVERY LOG (data/alert_log.jsonl)"
if [ ! -f "$ALERT_LOG_FILE" ]; then
  inconclusive "alert log missing: $ALERT_LOG_FILE — no evidence of any delivery"
  finish
fi
read -r last_ok attempts top_statuses <<<"$(_logstats "$ALERT_LOG_FILE" "$ALERT_MAX_AGE_S")"
if [ "${last_ok:-ERR}" = "ERR" ]; then
  inconclusive "alert log unreadable: $ALERT_LOG_FILE"
  finish
fi
if [[ "$last_ok" =~ ^[0-9]+$ ]] && [ "$last_ok" -gt 0 ]; then
  ok_age=$(( $(date +%s) - last_ok ))
  note "last confirmed delivery (ok=true) $(date -d "@$last_ok" '+%Y-%m-%d %H:%M:%S') — ${ok_age}s old"
else
  ok_age=""
  note "last confirmed delivery (ok=true): NONE on record"
fi
note "attempts in last ${ALERT_MAX_AGE_S}s: $attempts; top statuses: $top_statuses"

section "3. VERDICT"
if [ "$queued" -gt 0 ]; then
  if [ -n "$ok_age" ] && [ "$ok_age" -le "$ALERT_MAX_AGE_S" ]; then
    check 1 "$queued alert(s) queued despite a delivery ${ok_age}s ago — partial delivery (statuses: ${top_statuses})"
  else
    check 1 "$queued alert(s) undelivered and no confirmed delivery within ${ALERT_MAX_AGE_S}s (${top_statuses}) — money alerts are not reaching the operator"
  fi
elif [ "$attempts" -gt 0 ] && { [ -z "$ok_age" ] || [ "$ok_age" -gt "$ALERT_MAX_AGE_S" ]; }; then
  check 1 "$attempts attempt(s) in the last ${ALERT_MAX_AGE_S}s, none confirmed ok=true (${top_statuses}) — the lane runs and delivers nothing"
elif [ "$attempts" -gt 0 ]; then
  check 0 "queue empty and deliveries confirmed within ${ALERT_MAX_AGE_S}s"
else
  check 0 "queue empty and no attempts in ${ALERT_MAX_AGE_S}s (lane idle)"
fi

finish
