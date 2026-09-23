#!/usr/bin/env bash
# storage-watch v2 — anomaly-only watchdog for the nexus storage operation.
# Contract: SILENT when healthy (empty stdout => nothing is delivered).
# Asserts on ARTIFACTS THAT PROVE THE CLAIM, never on a guessed marker:
#   completion  = free space on /data/media grew materially (deletion happened)
#   stall       = nothing in the prune dir has moved AND free space is unchanged
# v1 was wrong: it treated `verify.done` (the *verification* pass) as "prune complete"
# and announced success with 452G free = the unchanged baseline, i.e. nothing reclaimed.
set +e
STATE=${STORAGE_WATCH_STATE:-/home/j_kro/.cache/storage-watch.state}
PRUNEDIR=${STORAGE_WATCH_DIR:-/home/j_kro/prune-20260923}
mkdir -p /home/j_kro/.cache
ALERTS=()

# --- read state (baseline free space, whether completion was already reported) ---
base=""; reported=""
[ -f "$STATE" ] && { base=$(awk -F= '/^base=/{print $2}' "$STATE"); reported=$(awk -F= '/^reported=/{print $2}' "$STATE"); }
free=$(df -BG --output=avail /data/media 2>/dev/null | tail -1 | tr -dc '0-9')
[ -z "$base" ] && base=$free          # first run: adopt current free as the baseline
[ -z "$reported" ] && reported=no

# 1. Free space below the prune's own stop condition.
if [ -n "$free" ] && [ "$free" -lt 100 ]; then
  ALERTS+=("media volume under 100G free (${free}G) - prune stop condition reached")
fi

# 2. The cancelled migration must not be running.
if pgrep -f "nvme1-migrat[e]" >/dev/null 2>&1; then
  ALERTS+=("CANCELLED migration relaunched ($(pgrep -fc 'nvme1-migrat[e]') rsync) - owner decision is cancel")
fi

# 3. Completion = free space actually grew (>50G above baseline). Report ONCE.
grew=$(( free - base ))
if [ "$grew" -gt 50 ] && [ "$reported" != "yes" ]; then
  ALERTS+=("prune COMPLETE: /data/media free is ${free}G, +${grew}G reclaimed (baseline ${base}G)")
  reported=yes
fi

# 4. Stall = no file in the prune dir has moved for >45 min AND space has not grown.
if [ -d "$PRUNEDIR" ]; then
  newest=$(find "$PRUNEDIR" -maxdepth 1 -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1)
  now=$(date +%s)
  if [ -n "$newest" ]; then
    idle_min=$(( (now - newest) / 60 ))
    if [ "$idle_min" -gt 45 ] && [ "$grew" -le 50 ]; then
      ALERTS+=("prune idle ${idle_min} min at ${free}G free (baseline ${base}G, +${grew}G) - stalled or dead")
    fi
  fi
fi

# 5. bcache state must stay 'no cache' until the P3 maintenance window.
st=$(cat /sys/block/bcache0/bcache/state 2>/dev/null)
[ -n "$st" ] && [ "$st" != "no cache" ] && ALERTS+=("bcache0 state changed to '${st}' - expected 'no cache' until P3")

# 6. The 96%-worn Kingston must stay out of service.
findmnt -rn -S /dev/nvme1n1 >/dev/null 2>&1 && ALERTS+=("worn Kingston is mounted again - it is retired")

printf 'base=%s\nreported=%s\n' "$base" "$reported" > "$STATE"

if [ ${#ALERTS[@]} -gt 0 ]; then
  echo "NEXUS STORAGE ALERT ($(date -u +%FT%TZ))"
  for a in "${ALERTS[@]}"; do echo "  - $a"; done
  exit 1
fi
exit 0
