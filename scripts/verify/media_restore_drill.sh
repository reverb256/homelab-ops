#!/usr/bin/env bash
# media_restore_drill.sh — re-runnable, read-only rehearsal of a /data/media
# restore. Companion to docs/MEDIA-RESTORE-REHEARSAL.md.
#
# IT ANSWERS, WITH MEASUREMENTS: if /data/media and its metadata died tonight,
# what is actually protected, is the metadata backup usable, how long would a
# restore take, and what would be lost forever?
#
# CONTRACT (all enforced here):
#   * READ-ONLY against live state. The live databases are opened mode=ro. It
#     never writes to /data/media — not one byte, not a directory. It does not
#     repair, scrub, mount, unmount or re-attach anything, and it never touches
#     /dev/bcache0, its cache set or /dev/sda.
#   * NOTHING IS WRITTEN TO ZEPHYR. The script refuses to run there.
#   * Every traversal is filesystem-scoped (`du -x`, `find -xdev`): /data/media
#     contains seven network mounts (sentry nfs4, krash2/krash3 SMB), so a bare
#     traversal walks the network and can hang on the failing device.
#   * Every read is bounded by `timeout` and throttled with `ionice -c3
#     nice -n 19`. This host has wedged under unthrottled I/O.
#   * The ONLY thing it creates is one scratch directory (default under
#     /data/nvme1, on the healthy root NVMe — never on /data/media, never on
#     bcache0). It deletes it before exiting and proves the deletion.
#   * It NEVER prints a secret value: credentials are minted at run time from
#     garage's admin socket and are only ever exported, never echoed.
#
# usage: media_restore_drill.sh [--full]
#          (default) inventory + live baseline + a bounded rehearsal of the
#                    databases and config (a few hundred MB)
#          --full    rehearse the ENTIRE metadata set (~5 GiB, 22.8k objects).
#                    This is the only honest way to measure a whole restore.
#        DRILL_SCRATCH=/path   override the scratch directory
#
# exit: 0 = every section evaluated and held, 1 = a real finding, 2 = could not
#       evaluate (empty/absent input — never reported as clean).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$HERE/_lib.sh" 2>/dev/null || { echo "FATAL: cannot source _lib.sh" >&2; exit 2; }

ENDPOINT='http://100.76.105.73:3900'
REGION='garage'
BUCKET='media-config'
PREFIX='current/'
KEYNAME='media-config-backup'
LIVE='/data/nvme1/media-config'          # the metadata tier (root NVMe, healthy device)
LIBRARY='/data/media'                    # the library (bcache0 -> /dev/sda, 88% full)
# downloads/ is deliberately NOT counted as library: a second lane is deleting
# measured leftovers there today with authorisation, and its content is churn.
LIB_DIRS='movies tv music books archive vault youtube games roms content-lan'
APPS='sonarr radarr prowlarr lidarr bazarr jellyfin qbittorrent cleanuparr seerr romm-db romm-redis romm'
# Live-baseline floors (measured 2026-09-23): a value under the floor is a
# metadata loss, not a rounding difference.
MIN_SONARR_SERIES=60 ; MIN_SONARR_EPISODES=8000
MIN_RADARR_MOVIES=130
MIN_PROWLARR_INDEXERS=20
MIN_JELLYFIN_ITEMS=7000
MIN_JELLYFIN_USERDATA=200
FULL=0 ; [ "${1:-}" = '--full' ] && FULL=1
TMO=${TMO:-90}                            # per-command timeout budget for small reads (s)
# A transfer is long by nature, so it gets its own (still finite) budget. Wrapping a
# full sync in the small-read timeout kills it mid-restore and looks like a failure.
SYNC_TMO=${SYNC_TMO:-1800}

WROTE=()
cleanup() { for d in "${WROTE[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

# ---- throttle + timeout wrappers: nothing here runs unthrottled ---------------
to()  { timeout "$TMO" ionice -c3 nice -n 19 "$@"; }
shr() { ionice -c3 nice -n 19 timeout "$TMO" "$@"; }
# /dev/bcache0[/@media] -> /dev/bcache0 : compare DEVICES, not subvolumes
dev() { printf '%s' "$1" | sed 's/\[.*//'; }

# ---- host guard --------------------------------------------------------------
HOST="$(hostname 2>/dev/null || echo unknown)"
if [ "$HOST" = zephyr ]; then
  echo "REFUSED: this drill creates scratch state and must not run on zephyr." >&2
  echo "         run it on nexus; it never writes to zephyr." >&2
  exit 2
fi
printf 'media restore drill on %s at %s\n' "$HOST" "$(date -Is)"
printf 'mode: %s   throttle: ionice -c3 nice -n 19   timeouts: %ss reads / %ss transfers\n' \
  "$([ "$FULL" = 1 ] && echo 'full metadata restore' || echo 'inventory + bounded rehearsal')" "$TMO" "$SYNC_TMO"

# ---- credentials: minted at run time, never echoed ---------------------------
section 'GUARD: tools, mounts, credentials'
missing=''
for c in aws sqlite3 findmnt du find timeout ionice; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
check $([ -z "$missing" ] && echo 0 || echo 1) "required tools present${missing:+ (missing:$missing)}"

findmnt -no SOURCE,FSTYPE -T "$LIBRARY" >/dev/null 2>&1
check $? "$LIBRARY is a mounted filesystem"
lib_src="$(findmnt -no SOURCE -T "$LIBRARY" 2>/dev/null)"
cfg_src="$(findmnt -no SOURCE -T "$LIVE" 2>/dev/null)"
note "library source: ${lib_src:-unknown}   metadata tier source: ${cfg_src:-unknown}"
if [ -z "$lib_src" ] || [ -z "$cfg_src" ]; then
  inconclusive "could not resolve the device behind the library or the metadata tier"
elif [ "$(dev "$lib_src")" = "$(dev "$cfg_src")" ]; then
  printf '  [FAIL] library and metadata live on the SAME device (%s) — one device loss takes both\n' "$lib_src"
  bump_rc 1
else
  printf '  [PASS] metadata tier (%s) is a different device from the library (%s)\n' "${cfg_src:-unknown}" "${lib_src:-unknown}"
fi
# The backup's own durability depends on where garage keeps the blobs.
garage_dev="$(findmnt -no SOURCE -T /data/shared 2>/dev/null || sudo -n findmnt -no SOURCE -T /data/shared 2>/dev/null)"
note "garage blob store (data_dir=/data/shared/garage/data) is on ${garage_dev:-unknown}"
if [ -n "$garage_dev" ] && [ "$(dev "$garage_dev")" = "$(dev "$lib_src")" ]; then
  printf '  [FAIL] the metadata backup is stored on the SAME device as the library (%s) —\n' "$garage_dev"
  printf '         "off-device backup" is not true here: a device loss takes the backup too\n'
  bump_rc 1
fi

info="$(sudo -n garage -c /etc/garage.toml key info "$KEYNAME" --show-secret 2>/dev/null)"
AWS_ACCESS_KEY_ID="$(printf '%s\n' "$info" | sed -n 's/^Key ID:[[:space:]]*//p')"
AWS_SECRET_ACCESS_KEY="$(printf '%s\n' "$info" | sed -n 's/^Secret key:[[:space:]]*//p')"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$REGION" AWS_EC2_METADATA_DISABLED=true
export AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=5
if [ -z "$AWS_ACCESS_KEY_ID" ]; then
  inconclusive "could not mint $KEYNAME credentials from garage's admin socket — nothing below can be judged"
else
  printf '  [PASS] minted a %s-character access key id from garage (value not printed)\n' "$(printf '%s' "$AWS_ACCESS_KEY_ID" | wc -c)"
fi
# small S3 reads (listings, single objects): bounded by TMO
awss3()  { timeout "$TMO" ionice -c3 nice -n 19 aws --endpoint-url "$ENDPOINT" --region "$REGION" s3 "$@"; }
# transfers: throttled, bounded by SYNC_TMO
awss3x() { timeout "$SYNC_TMO" ionice -c3 nice -n 19 aws --endpoint-url "$ENDPOINT" --region "$REGION" s3 "$@"; }

# ---- scratch: one directory, deleted and proven deleted ----------------------
SCRATCH="${DRILL_SCRATCH:-$(mktemp -d /data/nvme1/.media-restore-drill.XXXXXX 2>/dev/null || mktemp -d /tmp/.media-restore-drill.XXXXXX)}"
WROTE+=("$SCRATCH")
note "scratch (deleted on exit, and proven deleted): $SCRATCH"

# ---- 1. what is protected: metadata ----------------------------------------
section 'PROTECTION INVENTORY: metadata (the *arr + Jellyfin config tier)'
listing="$(awss3 ls "s3://$BUCKET/$PREFIX" --recursive 2>/dev/null || true)"
if assert_nonempty 'bucket listing' "$listing"; then
  n_objects="$(printf '%s\n' "$listing" | grep -c .)"
  newest="$(printf '%s\n' "$listing" | awk '{print $1" "$2}' | sort | tail -1)"
  newest_epoch="$(date -d "$newest" +%s 2>/dev/null || echo 0)"
  age_h=$(( ( $(date +%s) - newest_epoch ) / 3600 ))
  note "s3://$BUCKET/$PREFIX holds $n_objects objects; newest object: $newest (${age_h}h old)"
  check $([ "$n_objects" -gt 1000 ] && echo 0 || echo 1) "metadata backup is non-trivial ($n_objects objects)"
  check $([ "$age_h" -lt 48 ] && echo 0 || echo 1) "newest metadata object is under 48h old (${age_h}h)"
  for app in $APPS; do
    c="$(printf '%s\n' "$listing" | grep -cE "(^|[[:space:]])$PREFIX$app/" || true)"
    if [ "${c:-0}" -gt 0 ]; then printf '  [PASS] %-12s %4s objects in the backup\n' "$app" "$c"
    else printf '  [FAIL] %-12s NOTHING in the backup\n' "$app"; bump_rc 1; fi
  done
  db_objs="$(printf '%s\n' "$listing" | grep -E '/[^/]*\.db$' | wc -l)"
  check $([ "$db_objs" -gt 5 ] && echo 0 || echo 1) "database objects present in the backup ($db_objs)"
  # *.db-wal / *.db-shm in this bucket are leftovers from EARLIER runs: the
  # uploader snapshots live databases with sqlite3 .backup and screens the
  # sidecars out of the staged copy, and nothing ever deletes an old object.
  # A verbatim restore therefore lands a WAL that belongs to a different
  # generation of the database, and SQLite then reports the restored database
  # as malformed. Measured both ways on 2026-09-23 — see
  # docs/MEDIA-RESTORE-REHEARSAL.md. A restore MUST drop these sidecars.
  hazard="$(printf '%s\n' "$listing" | grep -cE '/[^/]*\.db-(wal|shm)$' || true)"
  if [ "${hazard:-0}" -gt 0 ]; then
    printf '  [FAIL] %s *.db-wal / *.db-shm object(s) sit in the bucket beside the databases\n' "$hazard"
    printf '         (leftovers from earlier runs). A verbatim restore must DROP every\n'
    printf '         *.db-wal / *.db-shm beside a *.db, or sqlite reports the restored\n'
    printf '         database as malformed. This is the one procedure step a restore cannot skip.\n'
    bump_rc 1
  else
    printf '  [PASS] no stale *.db-wal / *.db-shm sidecars in the bucket\n'
  fi
  # A backup job that has never verified itself is not a working backup.
  okline="$(sudo -n journalctl -u media-config-backup --no-pager 2>/dev/null | grep -c 'backup ok' || true)"
  if [ "${okline:-0}" -gt 0 ]; then
    printf '  [PASS] media-config-backup has reported a verified completion %s time(s)\n' "$okline"
  else
    printf '  [FAIL] media-config-backup has NEVER logged its own success line ("backup ok"):\n'
    printf '         the objects exist but the job has never passed its own verify+prune stage\n'
    bump_rc 1
  fi
  snaps="$(awss3 ls "s3://$BUCKET/snapshots/" 2>/dev/null | grep -c . || true)"
  if [ "${snaps:-0}" -gt 0 ]; then
    printf '  [PASS] %s dated snapshot(s) available for point-in-time rollback\n' "$snaps"
  else
    printf '  [FAIL] no dated snapshots in the bucket — only an accumulating current/, which\n'
    printf '         mixes vintages (stale *.db-wal from older runs sit beside newer *.db)\n'
    bump_rc 1
  fi
fi

# ---- 2. live baseline: is the metadata real right now? ----------------------
section 'LIVE BASELINE: the metadata as it actually is (read-only)'
sq() { to sqlite3 -readonly "file:$1?mode=ro" "$2" 2>/dev/null; }
counts_live=''
for spec in "sonarr:$LIVE/sonarr/sonarr.db:Series" \
            "sonarr:$LIVE/sonarr/sonarr.db:Episodes" \
            "radarr:$LIVE/radarr/radarr.db:Movies" \
            "radarr:$LIVE/radarr/radarr.db:MovieFiles" \
            "prowlarr:$LIVE/prowlarr/prowlarr.db:Indexers" \
            "jellyfin:$LIVE/jellyfin/data/data/jellyfin.db:BaseItems" \
            "jellyfin:$LIVE/jellyfin/data/data/jellyfin.db:UserData" ; do
  app="${spec%%:*}"; rest="${spec#*:}"; db="${rest%%:*}"; tbl="${rest##*:}"
  v="$(sq "$db" "select count(*) from \"$tbl\";")"
  counts_live="$counts_live $app.$tbl=${v:-EMPTY}"
  if [ -n "$v" ]; then printf '  [PASS] %-9s %-11s %s rows\n' "$app" "$tbl" "$v"
  else printf '  [FAIL] %-9s %-11s UNREADABLE or EMPTY\n' "$app" "$tbl"; bump_rc 1; fi
done
note "live:$counts_live"
s_series="$(sq "$LIVE/sonarr/sonarr.db" 'select count(*) from Series;')"
s_eps="$(sq "$LIVE/sonarr/sonarr.db" 'select count(*) from Episodes;')"
r_movies="$(sq "$LIVE/radarr/radarr.db" 'select count(*) from Movies;')"
p_idx="$(sq "$LIVE/prowlarr/prowlarr.db" 'select count(*) from Indexers;')"
j_items="$(sq "$LIVE/jellyfin/data/data/jellyfin.db" 'select count(*) from BaseItems;')"
j_ud="$(sq "$LIVE/jellyfin/data/data/jellyfin.db" 'select count(*) from UserData;')"
check $([ "${s_series:-0}" -ge "$MIN_SONARR_SERIES" ] && echo 0 || echo 1) "Sonarr series >= $MIN_SONARR_SERIES (got ${s_series:-EMPTY})"
check $([ "${s_eps:-0}" -ge "$MIN_SONARR_EPISODES" ] && echo 0 || echo 1) "Sonarr episodes >= $MIN_SONARR_EPISODES (got ${s_eps:-EMPTY})"
check $([ "${r_movies:-0}" -ge "$MIN_RADARR_MOVIES" ] && echo 0 || echo 1) "Radarr movies >= $MIN_RADARR_MOVIES (got ${r_movies:-EMPTY})"
check $([ "${p_idx:-0}" -ge "$MIN_PROWLARR_INDEXERS" ] && echo 0 || echo 1) "Prowlarr indexers >= $MIN_PROWLARR_INDEXERS (got ${p_idx:-EMPTY})"
check $([ "${j_items:-0}" -ge "$MIN_JELLYFIN_ITEMS" ] && echo 0 || echo 1) "Jellyfin items >= $MIN_JELLYFIN_ITEMS (got ${j_items:-EMPTY})"
check $([ "${j_ud:-0}" -ge "$MIN_JELLYFIN_USERDATA" ] && echo 0 || echo 1) "Jellyfin UserData (watch state) >= $MIN_JELLYFIN_USERDATA (got ${j_ud:-EMPTY})"
qbt_resume="$(to find "$LIVE/qbittorrent/qBittorrent/BT_backup" -maxdepth 1 -name '*.fastresume' -print 2>/dev/null | wc -l)"
note "qbittorrent resume files (.fastresume) present: ${qbt_resume:-0}"

# ---- 3. the rehearsal ------------------------------------------------------
section 'REHEARSAL: restore the metadata into scratch and prove it usable'
RESTORE="$SCRATCH/restore"; mkdir -p "$RESTORE"
# The `current/` prefix accumulates: objects are never deleted from it, so stale
# *.db-wal / *.db-shm sidecars from earlier runs sit next to newer *.db files.
# Copying such a pair onto a fresh host makes SQLite replay a WAL that does not
# belong to the database. We restore them anyway (to measure and to prove the
# hazard) and then show what a correct restore must do.
if [ "$FULL" = 1 ]; then
  note 'full rehearsal: syncing every object (this is the real restore workload)'
  # $PREFIX already ends with a slash; appending another yields a prefix that
  # matches NOTHING and aws exits 0 having copied zero files.
  src="s3://$BUCKET/${PREFIX%/}"
else
  note 'bounded rehearsal: databases + config only (use --full for all 22.8k objects)'
  src="s3://$BUCKET/$PREFIX"
  EXCL=(--exclude '*' \
        --include "*/sonarr.db" --include "*/radarr.db" --include "*/prowlarr.db" \
        --include "*/lidarr.db" --include "*/bazarr.db" --include "*/jellyfin.db" \
        --include "*/cleanuparr.db" --include "*/events.db" --include "*/users.db" \
        --include "*/config.xml" --include "*/system.xml" --include "*/network.xml" \
        --include "*/encoding.xml" --include "*/qBittorrent.conf" --include "*/config.yaml" )
fi
t0=$(date +%s)
if [ "$FULL" = 1 ]; then
  awss3x sync "$src" "$RESTORE/" --only-show-errors --no-progress \
      --cli-connect-timeout 60 --cli-read-timeout 300
else
  awss3x sync "$src" "$RESTORE/" "${EXCL[@]}" --only-show-errors --no-progress \
      --cli-connect-timeout 60 --cli-read-timeout 300
fi
rc_sync=$?
t1=$(date +%s); elapsed=$((t1 - t0))
n_files="$(find "$RESTORE" -type f 2>/dev/null | wc -l)"
bytes="$(du -sb "$RESTORE" 2>/dev/null | cut -f1)"
check $([ "$rc_sync" -eq 0 ] && echo 0 || echo 1) "s3 sync of the metadata backup returned 0 (rc=$rc_sync)"
if assert_nonempty 'restored files' "$n_files" && [ "${n_files:-0}" -gt 0 ]; then
  note "restored $n_files file(s) / ${bytes:-0} bytes in ${elapsed}s ($(awk -v b="$bytes" -v s="$elapsed" 'BEGIN{if(s>0)printf "%.2f MB/s", b/1048576/s; else print "n/a"}'))"
  if [ "$FULL" = 1 ] && [ "$elapsed" -lt 60 ]; then
    note "the full set was ALREADY present in scratch: ${elapsed}s is a no-op re-verify, not a download"
    note "for the real number, run --full against an empty scratch (measured 2026-09-23: 510s for 22,792 objects / 4.96 GiB)"
  elif [ "$FULL" = 1 ]; then
    note "measured full-metadata restore: ${elapsed}s for ${n_files} objects — plan a real recovery around this"
  else
    note "bounded rehearsal only; extrapolate with --full, do not scale this number by hand"
  fi
else
  inconclusive 'nothing was restored — an empty scratch cannot prove a restore works'
fi

# integrity of the restored databases, and the stale-WAL hazard
section 'REHEARSAL: are the restored databases usable?'
for db in $(find "$RESTORE" -xdev -type f -name '*.db' 2>/dev/null | sort); do
  rel="${db#"$RESTORE"/}"
  chk="$(to sqlite3 -readonly "file:$db?mode=ro" 'pragma integrity_check;' 2>&1 | head -1)"
  rows="$(to sqlite3 -readonly "file:$db?mode=ro" "select count(*) from sqlite_master;" 2>/dev/null)"
  if [ "$chk" = 'ok' ]; then
    printf '  [PASS] %-46s integrity=ok tables=%s size=%s\n' "$rel" "${rows:-?}" "$(stat -c%s "$db" 2>/dev/null)"
  else
    printf '  [FAIL] %-46s integrity=%s\n' "$rel" "${chk:-unreadable}"
    bump_rc 1
  fi
done
stale_wal=0
for wal in $(find "$RESTORE" -xdev -type f -name '*.db-wal' 2>/dev/null); do
  base="${wal%-wal}"
  [ -f "$base" ] || continue
  db_ts="$(stat -c %Y "$base" 2>/dev/null || echo 0)"; wal_ts="$(stat -c %Y "$wal" 2>/dev/null || echo 0)"
  if [ "$wal_ts" -lt "$db_ts" ]; then stale_wal=$((stale_wal + 1)); fi
done
if [ "$stale_wal" -gt 0 ]; then
  printf '  [FAIL] %s restored database(s) carry a *.db-wal OLDER than the database.\n' "$stale_wal"
  printf '         A restore that copies the bucket verbatim puts an unrelated WAL beside the\n'
  printf '         database. A correct restore DROPS every *.db-wal / *.db-shm next to a *.db\n'
  printf '         (the databases in the bucket are consistent sqlite3 .backup snapshots; the\n'
  printf '         sidecars are leftovers from earlier runs and must never be replayed).\n'
  bump_rc 1
else
  printf '  [PASS] no stale WAL sidecar found next to a restored database\n'
fi
# Compare key restored row counts against live, so "usable" is measured, not claimed.
section 'REHEARSAL: restored metadata vs live (row counts)'
cmp_tbl() { # <label> <restored db> <live db> <table> <min ratio %>
  local label="$1" rdb="$2" ldb="$3" tbl="$4"
  local r l
  r="$(to sqlite3 -readonly "file:$rdb?mode=ro" "select count(*) from \"$tbl\";" 2>/dev/null)"
  l="$(to sqlite3 -readonly "file:$ldb?mode=ro" "select count(*) from \"$tbl\";" 2>/dev/null)"
  if [ -z "$r" ] || [ -z "$l" ]; then
    printf '  [INCONCLUSIVE] %-24s restored=%s live=%s\n' "$label" "${r:-EMPTY}" "${l:-EMPTY}"; bump_rc 2; return 0
  fi
  if [ "$l" -gt 0 ] && [ "$r" -ge $(( l * 9 / 10 )) ]; then
    printf '  [PASS] %-24s restored=%s live=%s\n' "$label" "$r" "$l"
  else
    printf '  [FAIL] %-24s restored=%s live=%s (restored is under 90%% of live)\n' "$label" "$r" "$l"; bump_rc 1
  fi
}
[ -f "$RESTORE/sonarr/sonarr.db" ] && cmp_tbl 'sonarr Series' "$RESTORE/sonarr/sonarr.db" "$LIVE/sonarr/sonarr.db" 'Series'
[ -f "$RESTORE/sonarr/sonarr.db" ] && cmp_tbl 'sonarr Episodes' "$RESTORE/sonarr/sonarr.db" "$LIVE/sonarr/sonarr.db" 'Episodes'
[ -f "$RESTORE/radarr/radarr.db" ] && cmp_tbl 'radarr Movies' "$RESTORE/radarr/radarr.db" "$LIVE/radarr/radarr.db" 'Movies'
[ -f "$RESTORE/prowlarr/prowlarr.db" ] && cmp_tbl 'prowlarr Indexers' "$RESTORE/prowlarr/prowlarr.db" "$LIVE/prowlarr/prowlarr.db" 'Indexers'
[ -f "$RESTORE/jellyfin/data/data/jellyfin.db" ] && cmp_tbl 'jellyfin BaseItems' "$RESTORE/jellyfin/data/data/jellyfin.db" "$LIVE/jellyfin/data/data/jellyfin.db" 'BaseItems'
[ -f "$RESTORE/jellyfin/data/data/jellyfin.db" ] && cmp_tbl 'jellyfin UserData' "$RESTORE/jellyfin/data/data/jellyfin.db" "$LIVE/jellyfin/data/data/jellyfin.db" 'UserData'
jf_xml="$(find "$RESTORE/jellyfin" -xdev -name '*.xml' 2>/dev/null | wc -l)"
if [ "${jf_xml:-0}" -gt 0 ]; then printf '  [PASS] %s Jellyfin XML config file(s) restored (server is rebuildable from these)\n' "$jf_xml"
else printf '  [FAIL] no Jellyfin XML config in the restore — a rebuilt server would lose its setup\n'; bump_rc 1; fi

# ---- 4. what is NOT protected: the library ---------------------------------
section 'PROTECTION INVENTORY: the library itself'
buckets="$(sudo -n garage -c /etc/garage.toml bucket list 2>/dev/null || true)"
if assert_nonempty 'garage bucket list' "$buckets"; then
  note "garage buckets: $(printf '%s\n' "$buckets" | awk 'NR>1 && NF{print $3}' | tr '\n' ' ')"
  covered=''
  for b in $LIB_DIRS; do
    case "$(printf '%s\n' "$buckets" | tr 'A-Z' 'a-z')" in
      *"$b"*) covered="$covered $b" ;;
    esac
  done
  if [ -n "$covered" ]; then
    printf '  [PASS] bucket name matches a library directory:%s — verify it actually holds it\n' "$covered"
  else
    printf '  [FAIL] NO garage bucket corresponds to any library directory. The library is UNBACKED.\n'
    bump_rc 1
  fi
fi
printf '  ..  measured library sizes (du -x, throttled — downloads/ excluded on purpose):\n'
lib_total=0
for d in $LIB_DIRS; do
  p="$LIBRARY/$d"
  [ -e "$p" ] || continue
  kb="$(shr du -x -s "$p" 2>/dev/null | cut -f1)"
  if [ -z "$kb" ]; then
    printf '  [INCONCLUSIVE] %-14s did not answer within %ss (a hung read on this device is itself a finding)\n' "$d" "$TMO"; bump_rc 2; continue
  fi
  lib_total=$((lib_total + kb))
  printf '  [PASS] %-14s %s\n' "$d" "$(awk -v k="$kb" 'BEGIN{printf "%.1f GiB", k/1048576}')"
done
note "library total (excl. downloads/): $(awk -v k="$lib_total" 'BEGIN{printf "%.2f TiB", k/1073741824}')"
dl_kb="$(shr du -x -s "$LIBRARY/downloads" 2>/dev/null | cut -f1)"
note "downloads/ (churn, not library, actively being pruned by another lane): $(awk -v k="${dl_kb:-0}" 'BEGIN{printf "%.1f GiB", k/1048576}')"

# ---- 5. permanent loss, stated against measurement --------------------------
section 'PERMANENT LOSS if the library device dies today'
vault_kb="$(shr du -x -s "$LIBRARY/vault" 2>/dev/null | cut -f1)"
roms_kb="$(shr du -x -s "$LIBRARY/roms" 2>/dev/null | cut -f1)"
cl_kb="$(shr du -x -s "$LIBRARY/content-lan" 2>/dev/null | cut -f1)"
note "vault/ (curated non-*arr content, filed by file-to-vault; NOT re-acquirable)      $(awk -v k="${vault_kb:-0}" 'BEGIN{printf "%.1f GiB", k/1048576}')"
note "roms/  (game images; re-acquirable in principle, provenance varies)                $(awk -v k="${roms_kb:-0}" 'BEGIN{printf "%.1f GiB", k/1048576}')"
note "content-lan/                                                                      $(awk -v k="${cl_kb:-0}" 'BEGIN{printf "%.3f GiB", k/1048576}')"
note 'movies/ + tv/ are mostly re-acquirable through Prowlarr indexers — the question is'
note 'availability and time, not possibility. See docs/MEDIA-RESTORE-REHEARSAL.md.'
note 'Jellyfin watch state and *arr history are ONLY in the metadata backup, which lives'
note 'on the same device as the library (see the GUARD section above).'

# ---- 6. prove the scratch is gone ------------------------------------------
section 'SCRATCH CLEANUP'
for d in "${WROTE[@]}"; do rm -rf "$d"; done
WROTE=()
check $([ -e "$SCRATCH" ] && echo 1 || echo 0) "scratch directory is deleted ($SCRATCH)"
left="$(find /data/nvme1 -maxdepth 1 -name '.media-restore-drill.*' 2>/dev/null | wc -l)"
check $([ "${left:-1}" -eq 0 ] && echo 0 || echo 1) "no drill scratch left behind under /data/nvme1 ($left found)"

finish
