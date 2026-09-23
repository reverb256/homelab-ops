#!/usr/bin/env bash
# test-backup-failure-visibility.sh — the sweep's findings must stay dead.
#
# What this pins (each assertion is a failure the fleet has actually had):
#   1. backup-stall-watchdog detects a FAILED backup unit by DISCOVERY, so a backup
#      added tomorrow is covered without editing a list.
#      Live instance 2026-09-22: media-config-backup.service sat Result=exit-code /
#      ActiveState=failed since 12:38:57 with no reader anywhere.
#   2. ... reports clean only when nothing is found (negative control), never kills a
#      failed unit, and still kills a stalled one — including one that is NOT in the
#      static list (the old class: coverage that rots because it is a hand-written list).
#   3. mining-scheduler.sh acts on the miners the CLUSTER has. The old hardcoded map
#      named deployments that no longer exist (xmrig-nexus, gpu-miner-forge-*): it
#      scaled nothing and printed "✓ Miners paused". An empty discovery now fails loudly.
#
# PATH shims for systemctl/curl/kubectl: no cluster object, no real unit, no file
# outside the test's temp dir is touched. Run on nexus:
#   bash tests/test-backup-failure-visibility.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
W="$ROOT/omarchy/nexus/bin/backup-stall-watchdog"
S="$ROOT/scripts/mining-scheduler.sh"
PASS=0 FAIL=0
ok(){ printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
expect(){ [ "$1" = "$2" ] && ok "$3 ($2)" || no "$3 (want $1 got $2)"; }
contains(){ printf '%s' "$2" | grep -qF -- "$1" && ok "$3" || no "$3 (missing: $1)"; }
lacks(){ printf '%s' "$2" | grep -qF -- "$1" && no "$3 (unexpected: $1)" || ok "$3"; }

[ -x "$W" ] && ok "watchdog is executable" || no "watchdog missing: $W"
[ -x "$S" ] && ok "mining-scheduler is executable" || no "mining-scheduler missing: $S"

# ---- 1. self-test (positive + negative controls of the pure predicate)
ST=$(DRY_RUN=1 "$W" --selftest 2>&1); rc=$?
expect 0 "$rc" "watchdog --selftest exit 0"
contains "WATCHDOG_DETECTS" "$ST" "watchdog self-test reports detection"

# ---- 2. detection is by discovery, not by a static list
grep -q 'list-units --all --type=service' "$W" && ok "loaded services are discovered from systemd" \
                                            || no "watchdog does not discover loaded services"
grep -q 'state=failed' "$W" && ok "failed units are discovered from systemd" \
                            || no "watchdog does not scan systemd for failed units"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
STALL_START="$(date -d '3 hours ago' '+%Y-%m-%d %H:%M:%S %Z')"

# systemctl shim: drives discovery (list-units --all), failure list, and show props.
mk_shims(){  # $1 = failed unit (empty = none), $2 = stalled unit (empty = none)
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/systemctl" <<EOF
#!/usr/bin/env bash
FAILED_UNIT="$1"
STALL_UNIT="$2"                          # deliberately NOT in the static UNITS list
STALL_START="$STALL_START"
all="\$*"
case "\$all" in *"--user list-units"*) exit 0 ;; esac
case "\$all" in
  *"list-units"*"state=failed"*)
    [ -n "\$FAILED_UNIT" ] && echo "\$FAILED_UNIT loaded failed failed A backup"
    exit 0 ;;
  *"list-units"*)
    echo "memlawb-backup.service loaded active exited Memory ledger backup"
    echo "\$STALL_UNIT loaded activating start A backup that hangs"
    exit 0 ;;
esac
unit=""; for a in "\$@"; do case "\$a" in *.service) unit="\$a" ;; esac; done
prop=""; prev=""
for a in "\$@"; do [ "\$prev" = "-p" ] && prop="\$a"; prev="\$a"; done
case "\$prop" in
  LoadState) echo loaded ;;
  ActiveState)
    if [ "\$unit" = "\$STALL_UNIT" ]; then echo activating
    elif [ "\$unit" = "\$FAILED_UNIT" ]; then echo failed
    else echo inactive; fi ;;
  Result)
    if [ "\$unit" = "\$FAILED_UNIT" ]; then echo exit-code; else echo success; fi ;;
  ExecMainExitTimestamp)
    if [ "\$unit" = "\$FAILED_UNIT" ]; then echo "Tue 2026-09-22 12:38:57 CDT"; else echo ""; fi ;;
  ActiveEnterTimestamp)
    if [ "\$unit" = "\$STALL_UNIT" ]; then echo "\$STALL_START"; else echo ""; fi ;;
  NRestarts) echo 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
  cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat >> "${CURL_CAPTURE:-/dev/null}" 2>/dev/null
echo "200"
EOF
  chmod +x "$TMP/bin/systemctl" "$TMP/bin/curl"
}

# ---- 2a. POSITIVE: a failed backup must be reported and pushed
mk_shims "media-config-backup.service" ""
: > "$TMP/alerts.json"
OUT=$(PATH="$TMP/bin:$PATH" CURL_CAPTURE="$TMP/alerts.json" ALERT_URL="http://test.invalid/alerts" "$W" 2>&1); rc=$?
expect 1 "$rc" "watchdog exits non-zero when a backup has failed"
contains "[BACKUP-FAILED]" "$OUT" "failed backup is named in the output"
contains "media-config-backup.service" "$OUT" "the failed unit is identified"
[ -s "$TMP/alerts.json" ] && ok "failure was pushed to the fleet alert feed" || no "no alert payload posted"
contains "BackupNotRestorable" "$(cat "$TMP/alerts.json" 2>/dev/null)" "alert name is stable for routing"

# ---- 2b. NEGATIVE: nothing failed, nothing stalled -> clean, exit 0
mk_shims ""
: > "$TMP/alerts2.json"
OUT=$(PATH="$TMP/bin:$PATH" CURL_CAPTURE="$TMP/alerts2.json" "$W" 2>&1); rc=$?
expect 0 "$rc" "watchdog exits 0 when every backup is fine"
lacks "[BACKUP-FAILED]" "$OUT" "no false failure reported"
contains "reported 0 failed" "$OUT" "clean run says so explicitly"

# ---- 2c. STALL: a discovered (not statically listed) stalled backup is still killed
mk_shims "" "stalled-backup.service"
OUT=$(PATH="$TMP/bin:$PATH" DRY_RUN=1 STALL_MIN=90 "$W" 2>&1); rc=$?
expect 1 "$rc" "stall makes the watchdog fail loudly"
contains "would kill stalled-backup.service" "$OUT" "a stalled backup NOT in the static list is still actioned"

# ---- 3. mining-scheduler acts on cluster state, and fails loudly on an empty set
cat > "$TMP/bin/kubectl" <<'KEOF'
#!/usr/bin/env bash
if [ "${EMPTY_DISCOVERY:-0}" = "1" ]; then exit 0; fi
args="$*"
case "$args" in
  *"get deploy -n mining"*jsonpath*)
    printf 'peakminer-nexus-3060ti\npeakminer-forge-4060-0\nllama-nexus-3060ti\n'; exit 0 ;;
  *"get deploy -n mining peakminer-nexus-3060ti"*) echo nexus; exit 0 ;;
  *"get deploy -n mining peakminer-forge-4060-0"*) echo forge; exit 0 ;;
  *"scale deployment"*) echo "deployment.apps scaled"; exit 0 ;;
esac
exit 0
KEOF
chmod +x "$TMP/bin/kubectl"

OUT=$(EMPTY_DISCOVERY=1 PATH="$TMP/bin:$PATH" DRY_RUN=1 STATE_FILE="$TMP/paused" "$S" pause 2>&1); rc=$?
expect 2 "$rc" "empty miner discovery exits non-zero (no more silent no-op)"
contains "no miner Deployments discovered" "$OUT" "empty discovery says so"
lacks "Miners paused" "$OUT" "empty discovery must NOT print success"

OUT=$(PATH="$TMP/bin:$PATH" DRY_RUN=1 STATE_FILE="$TMP/paused" "$S" pause 2>&1); rc=$?
expect 0 "$rc" "a non-empty discovery pauses successfully (dry run)"
contains "peakminer-nexus-3060ti" "$OUT" "the cluster-derived miner set is acted on"
lacks "xmrig-nexus" "$OUT" "retired native unit names are gone"

OUT=$(PATH="$TMP/bin:$PATH" DRY_RUN=1 STATE_FILE="$TMP/paused" "$S" status 2>&1)
lacks "xmrig-nexus" "$OUT" "status no longer advertises retired names"

echo
echo "== PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0