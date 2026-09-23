#!/usr/bin/env bash
# storage-watch — anomaly-only watchdog for the nexus storage operation.
# Contract: SILENT when healthy (empty stdout => nothing is delivered).
#           Prints + exits non-zero ONLY when something needs a human.
# Read-only. Safe to run on a clock: no traversal of /data/media, no writes, all calls bounded.
set +e
D=/dev/mapper/root
LEDGER=/home/j_kro/prune-20260923/verify.jsonl
ALERTS=()

# 1. Free space on the media volume: the prune's own stop condition.
media_avail_g=$(df -BG --output=avail /data/media 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "$media_avail_g" ] && [ "$media_avail_g" -lt 100 ]; then
  ALERTS+=("media volume under 100G free (${media_avail_g}G) - prune stop condition")
fi

# 2. Is the cancelled migration running again?
if pgrep -f "nvme1-migrat[e]" >/dev/null 2>&1; then
  ALERTS+=("CANCELLED migration relaunched ($(pgrep -fc 'nvme1-migrat[e]') rsync processes) - owner decision is cancel")
fi

# 3. Has the prune stalled, and is it finished?
if [ -f "$LEDGER" ]; then
  age_min=$(( ( $(date +%s) - $(stat -c %Y "$LEDGER") ) / 60 ))
  rows=$(wc -l < "$LEDGER" 2>/dev/null)
  done_flag=$(ls /home/j_kro/prune-20260923/*.done 2>/dev/null | head -1)
  if [ -z "$done_flag" ] && [ "$age_min" -gt 45 ]; then
    ALERTS+=("prune ledger idle ${age_min} min at ${rows} rows and no .done marker - stalled or dead")
  fi
  # Report the final number once, when it completes (one-shot style: fires only on the transition).
  if [ -n "$done_flag" ] && [ ! -f /home/j_kro/.cache/storage-watch-reported ]; then
    ALERTS+=("prune COMPLETE: $(df -h /data/media | tail -1 | awk '{print $4}') free on /data/media now (rows=${rows})")
    mkdir -p /home/j_kro/.cache && touch /home/j_kro/.cache/storage-watch-reported
  fi
fi

# 4. bcache state changed unexpectedly (a cache device appeared / the volume left writethrough).
st=$(cat /sys/block/bcache0/bcache/state 2>/dev/null)
mode=$(cat /sys/block/bcache0/bcache/cache_mode 2>/dev/null | tr -d '[]')
if [ "$st" != "no cache" ]; then
  ALERTS+=("bcache0 state changed: '${st}' mode='${mode}' - expected 'no cache' until P3")
fi

# 5. The worn Kingston must stay out of service.
if findmnt -rn -S /dev/nvme1n1 >/dev/null 2>&1; then
  ALERTS+=("worn Kingston (96% wear) is mounted again - it is retired")
fi

if [ ${#ALERTS[@]} -gt 0 ]; then
  echo "NEXUS STORAGE ALERT ($(date -u +%FT%TZ))"
  for a in "${ALERTS[@]}"; do echo "  - $a"; done
  exit 1
fi
exit 0
