#!/usr/bin/env bash
# leftover-occupancy - D9: re-runnable occupancy audit of the media downloads dir.
#
# Detection only. Never deletes. Re-runs the same proof the manifest was built
# from (device scope, hardlink count, sonarr/radarr/jellyfin library references,
# download-client state) so occupancy can be re-audited later without
# re-deriving the proof by hand.
#
# Output matches scripts/verify/silent-failure-sweep.sh:
#   verdict | section | item | signal | expected
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MEDIA_DIR="$(cd "$HERE/../media" 2>/dev/null && pwd || echo "$HERE/../media")"
ROOT="${MEDIA_DOWNLOADS:-/data/media/downloads}"
OUT="$(mktemp)"
emit() { printf '%-9s | %-22s | %-46s | %-52s | %s\n' "$1" "$2" "$3" "$4" "$5"; }

if ! [ -d "$ROOT" ]; then
  emit NOTE D9 downloads-missing "$ROOT" "not present here" "run on the node that owns the pool"
  exit 0
fi

# 1. pool occupancy (this is what DiskSpaceLow keys on)
read -r SIZE USED AVAIL PCT <<<"$(df -B1 --output=size,used,avail,pcent "$ROOT" | tail -1)"
SIZE_MB=$((SIZE / 1048576)); AVAIL_MB=$((AVAIL / 1048576))
SIG="used=$((USED / 1000000000))GB avail=$((AVAIL / 1000000000))GB pct=${PCT}"
if [ "${PCT%\%}" -ge 85 ]; then
  emit FINDING D9 pool-pressure "$ROOT" "$SIG" "below 85 pct used"
else
  emit OK D9 pool-pressure "$ROOT" "$SIG" "below 85 pct used"
fi

# 2. leftover manifest, rebuilt in dry-run (never deletes)
bash "$MEDIA_DIR/apply-leftovers.sh" --root "$ROOT" --top 5 --json "$OUT" >"$OUT.txt" 2>"$OUT.err"
if [ ! -s "$OUT" ]; then
  emit FINDING D9 manifest-unavailable "$MEDIA_DIR/reclaim-leftovers.py" "no manifest produced" "a manifest with per-item proofs"
  sed -n '1,5p' "$OUT.err" | sed 's/^/            /'
  rm -f "$OUT" "$OUT.txt" "$OUT.err"
  exit 1
fi

emit_out="$(python3 - "$OUT" "$AVAIL_MB" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
avail_mb = int(sys.argv[2])
elig = d["eligible"]
tot = sum(r["bytes"] for r in elig)
cats = d.get("categories", {})
src = d.get("proof_sources", {})
def e(v, s, i, sig, exp): print("%s|%s|%s|%s|%s" % (v, s, i, sig, exp))
if tot:
    pct_of_avail = 100.0 * tot / (tot + avail_mb * 1048576)
    e("FINDING", "D9 leftovers", d["root"],
      "%d items / %.1f GB reclaimable (%.1f pct of pool)" % (len(elig), tot / 1e9, pct_of_avail),
      "leftover set within the agreed budget")
else:
    e("OK", "D9 leftovers", d["root"], "0 reclaimable items", "0 reclaimable items")
e("NOTE", "D9 categories", "leftover classes",
  "eligible=%d active=%d hardlinked=%d unknown=%d" % (
      cats.get("eligible-and-unreferenced", 0),
      cats.get("still-active-in-download-client", 0),
      cats.get("hardlinked-into-library", 0),
      cats.get("genuinely-unknown", 0)),
  "every item carries a proof class")
missing = [k for k, v in src.items() if not v.startswith("ok")]
if missing:
    e("FINDING", "D9 proof-source", ",".join(missing), "not readable", "all proof sources readable")
else:
    e("OK", "D9 proof-source", "library+client", "; ".join("%s: %s" % (k, v) for k, v in src.items()),
      "all proof sources readable")
PY
)"
printf '%s\n' "$emit_out" | while IFS='|' read -r v s i sig exp; do emit "$v" "$s" "$i" "$sig" "$exp"; done
rm -f "$OUT" "$OUT.txt" "$OUT.err"
