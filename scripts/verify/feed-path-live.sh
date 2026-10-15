#!/usr/bin/env bash
# scripts/verify/feed-path-live.sh
#
# Guards the 2026-10-15 RHC feed outage (nexus, ~/Work/trading).
#
# What happened: the relay's long-lived upstream handshake was dropped by the third party
# (relay log `readData returned EOF url=wss://feed.mainnet.chain.robinhood.com` ->
# `ERROR no connected feed`), and every reconnect since is refused with HTTP 403
# ("this source address range has been blocked"). The nexus lane ledger froze with it
# (data/feed_lane.jsonl stopped advancing) and forge's standby copy had stopped ~2h
# earlier -- so BOTH feed paths were dead for >80 min while data/feed_health.json still
# reported  "verdict": "ok".
#
# Why the health file lied: feed_health judges on relay.connected / relay.upgraded, which
# are stale *state* fields -- they stay true after the socket is gone. The only field that
# moves is relay.data_frames; a frozen counter means a dead path regardless of what
# connected/upgraded claim. That is the false-PASS this script exists to catch.
#
# So this script does NOT ask "is the feed healthy" -- the upstream block is not ours to
# fix and `verdict: external` is an honest answer. It asks the question the outage
# exposed: does `verdict: ok` correspond to a live path anywhere? A path is live when
#   A) data/feed_lane.jsonl advanced within FEED_MAX_AGE_S (the relay-fed nexus ledger), or
#   B) relay.data_frames is climbing between two samples.
#   verdict ok + no live path            -> FAIL (monitor false-PASSing)
#   verdict ok + a path unknown, none live -> INCONCLUSIVE (cannot prove either way)
#   verdict != ok                        -> informational: rows say so; paths are printed
#   health file missing/unparseable      -> INCONCLUSIVE (never a "clean" result)
#
# EXPECTED RED DURING AN UPSTREAM BLOCK: while `upstream.blocked=true` this gate stays red
# with verdict still ok. That is the point -- it names the false-PASS instead of letting
# the health file's "ok" stand, and it clears when either path resumes.
#
# HOST: nexus (~/Work/trading). kubectl not required. cwd: anywhere.
# READ-ONLY: reads two data files and re-reads one of them. Writes nothing, touches no
#   service -- in particular it does NOT restart rhc-feed-relay. During a block the relay
#   is already retrying on the same blocked egress IP, so a restart only re-enters the
#   same 403 loop (and suspending the lane is a rejected change -- see trading-k8s history
#   `Revert "py-job: support spec.suspend; suspend feed-lane + feed-forge"`).
# Exit: 0 = OK, 1 = FAIL, 2 = INCONCLUSIVE.
# Overrides (so the gate can be proven to fire AND not to false-fire):
#   TRADING_ROOT FEED_HEALTH_FILE FEED_LANE_FILE FEED_MAX_AGE_S FEED_RELAY_SAMPLE_S
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$HERE/_lib.sh"

: "${TRADING_ROOT:=$HOME/Work/trading}"
: "${FEED_HEALTH_FILE:=$TRADING_ROOT/data/feed_health.json}"
: "${FEED_LANE_FILE:=$TRADING_ROOT/data/feed_lane.jsonl}"
: "${FEED_MAX_AGE_S:=900}"
: "${FEED_RELAY_SAMPLE_S:=15}"

command -v "$PY" >/dev/null 2>&1 || { echo "INCONCLUSIVE: python not found (run on nexus)"; exit 2; }

echo "verify/feed-path-live.sh  host=$(hostname)  read-only"
echo "  health=$FEED_HEALTH_FILE"
echo "  lane=$FEED_LANE_FILE  max_age=${FEED_MAX_AGE_S}s  relay_sample=${FEED_RELAY_SAMPLE_S}s"
_hr

# _field <file> <dotted.path> -> value, or MISSING / ERR
_field() {
  "$PY" - "$1" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as fh:
        doc = json.load(fh)
except Exception:
    print("ERR")
    sys.exit(0)
cur = doc
for part in sys.argv[2].split("."):
    if not isinstance(cur, dict) or part not in cur:
        print("MISSING")
        sys.exit(0)
    cur = cur[part]
if isinstance(cur, bool):
    print("true" if cur else "false")
elif cur is None:
    print("null")
else:
    print(cur)
PY
}

section "1. HEALTH FILE"
if [ ! -f "$FEED_HEALTH_FILE" ]; then
  inconclusive "health file missing: $FEED_HEALTH_FILE"
  finish
fi
verdict="$(_field "$FEED_HEALTH_FILE" verdict)"
frames1="$(_field "$FEED_HEALTH_FILE" relay.data_frames)"
connected="$(_field "$FEED_HEALTH_FILE" relay.connected)"
blocked="$(_field "$FEED_HEALTH_FILE" upstream.blocked)"
h_ts="$(_field "$FEED_HEALTH_FILE" ts)"
if [ -z "$verdict" ] || [ "$verdict" = "ERR" ]; then
  inconclusive "health file unparseable: $FEED_HEALTH_FILE (schema drift, not a clean result)"
  finish
fi
note "verdict=$verdict upstream.blocked=$blocked relay.connected=$connected relay.data_frames=$frames1"
note "NOTE relay.connected/upgraded are stale state; only data_frames moving proves a live path"
if [[ "$h_ts" =~ ^[0-9]+$ ]]; then
  note "health ts=$h_ts age=$(( $(date +%s) - h_ts ))s"
else
  note "health ts=$h_ts (not numeric)"
fi

section "2. PATH A — nexus lane ledger advancing"
lane=0   # 0 = not live, 1 = live
# _could: an unreadable/missing artifact is INCONCLUSIVE only while `verdict: ok` is the
# claim under test. Under an honest degraded verdict the consistency question does not
# depend on this path, so a rotated/missing file must not poison the whole run (that would
# turn a legitimately-degraded feed into a red gate).
_could() { if [ "$verdict" = "ok" ]; then inconclusive "$1"; else note "not evaluated (verdict=$verdict): $1"; fi; }
if [ ! -f "$FEED_LANE_FILE" ]; then
  _could "lane ledger missing: $FEED_LANE_FILE"
  lane=-1
else
  mtime="$(stat -c %Y "$FEED_LANE_FILE" 2>/dev/null || echo "")"
  last="$(tail -n 1 "$FEED_LANE_FILE" 2>/dev/null | "$PY" -c 'import json,sys
try: print(json.loads(sys.stdin.read())["ts"])
except Exception: print("")' 2>/dev/null)"
  if [[ "$mtime" =~ ^[0-9]+$ ]]; then
    age=$(( $(date +%s) - mtime ))
    note "ledger mtime age=${age}s last_row_ts=${last:-MISSING}"
    if [ "$age" -lt "$FEED_MAX_AGE_S" ]; then lane=1; fi
  else
    _could "cannot stat lane ledger mtime: $FEED_LANE_FILE"
    lane=-1
  fi
fi
case "$lane" in
  1) note "PATH A: LIVE (ledger advanced within ${FEED_MAX_AGE_S}s)" ;;
  0) note "PATH A: DEAD (ledger frozen longer than ${FEED_MAX_AGE_S}s)" ;;
  *) note "PATH A: UNKNOWN" ;;
esac

section "3. PATH B — relay data_frames climbing"
relay=0  # 0 = not live, 1 = live, -1 = unknown
if [ "${FEED_RELAY_SAMPLE_S:-0}" -gt 0 ] 2>/dev/null; then
  note "sampling ${FEED_RELAY_SAMPLE_S}s ..."
  sleep "$FEED_RELAY_SAMPLE_S"
  frames2="$(_field "$FEED_HEALTH_FILE" relay.data_frames)"
else
  frames2="$frames1"
  note "sampling disabled (FEED_RELAY_SAMPLE_S=$FEED_RELAY_SAMPLE_S)"
fi
if [[ "$frames1" =~ ^[0-9]+$ ]] && [[ "$frames2" =~ ^[0-9]+$ ]]; then
  note "data_frames $frames1 -> $frames2 (delta $(( frames2 - frames1 )))"
  if [ "$frames2" -gt "$frames1" ]; then relay=1; fi
else
  _could "cannot compare relay.data_frames ($frames1 -> $frames2)"
  relay=-1
fi
case "$relay" in
  1) note "PATH B: LIVE (frames climbing)" ;;
  0) note "PATH B: DEAD (frames frozen at $frames2)" ;;
  *) note "PATH B: UNKNOWN" ;;
esac

section "4. VERDICT CONSISTENCY"
if [ "$verdict" = "ok" ]; then
  if [ "$lane" = 1 ] || [ "$relay" = 1 ]; then
    check 0 "verdict ok is backed by a live path (lane=$lane relay=$relay)"
  elif [ "$lane" = 0 ] && [ "$relay" = 0 ]; then
    check 1 "verdict ok but NO live feed path (lane dead, relay data_frames frozen at $frames2) — health reporter false-PASS"
  else
    inconclusive "verdict ok, no path proven live, and lane=$lane relay=$relay is unknown — cannot prove or disprove"
  fi
else
  note "verdict '$verdict' is an honest degraded verdict; nothing is being hidden"
  check 0 "health file reports the degradation itself (lane=$lane relay=$relay)"
fi

finish
