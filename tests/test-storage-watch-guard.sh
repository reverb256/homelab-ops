#!/usr/bin/env bash
# test-storage-watch-guard.sh — the prune-ledger idle guard must fire, and must not false-fire.
#
# What this pins (kanban t_403fa507; each assertion is a real failure mode):
#   A guard that never fires is indistinguishable from a fixed one. The salvaged
#   edit (nexus mirror working tree, 2026-09-23) used:
#       x=$(grep -c ... || echo 0); [ "$x" -eq 0 ]
#   On no match grep prints "0" AND exits 1, so x was "0\n0", the [ -eq ] test
#   errored (rc 2), and the alert was suppressed in BOTH cases — including the
#   stalled case it exists to catch. It was merged only after this test went
#   red on that revision and green on the fix ("${x:-0}").
#
#   Three fixtures run the REAL script (K3s shimmed out; only the ledger section
#   is judged, by exact line):
#     terminal : idle >30 min WITH a terminal status (run-verified|run-complete) -> no alert
#     open     : idle >30 min WITHOUT a terminal status                          -> alert fires
#     fresh    : written <30 min ago                                             -> no alert
#
# Run on nexus:  bash tests/test-storage-watch-guard.sh
# Test another revision:
#   STORAGE_WATCH_UNDER_TEST=/path/to/storage-watch.sh bash tests/test-storage-watch-guard.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SW="${STORAGE_WATCH_UNDER_TEST:-$ROOT/scripts/verify/storage-watch.sh}"
PASS=0 FAIL=0
ok(){ printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
contains(){ printf '%s' "$2" | grep -qF -- "$1" && ok "$3" || no "$3 (missing: $1)"; }
lacks(){ printf '%s' "$2" | grep -qF -- "$1" && no "$3 (unexpected: $1)" || ok "$3"; }

[ -x "$SW" ] && ok "script under test is executable ($SW)" || no "script under test missing: $SW"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fix" "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/k3s"; chmod +x "$TMP/bin/k3s"   # cluster section not under test

printf '{"ts":1,"status":"deleted","path":"a"}\n{"ts":2,"status":"run-complete","note":"done"}\n' > "$TMP/fix/terminal.jsonl"
printf '{"ts":1,"status":"deleted","path":"a"}\n{"ts":2,"status":"deleted","path":"b"}\n'              > "$TMP/fix/open.jsonl"
printf '{"ts":1,"status":"deleted"}\n'                                                                 > "$TMP/fix/fresh.jsonl"
touch -d '2 hours ago' "$TMP/fix/terminal.jsonl" "$TMP/fix/open.jsonl"

run_case(){ # $1 = fixture file name; prints the script's combined output
  PATH="$TMP/bin:$PATH" STORAGE_WATCH_TIMEOUT=10 STORAGE_WATCH_LEDGER="$TMP/fix/$1" \
    STORAGE_WATCH_STATE="$TMP/state.$1" timeout 45 bash "$SW" 2>&1 || true
}

OUT=$(run_case terminal.jsonl)
lacks "prune ledger idle" "$OUT" "terminal status: idle ledger does NOT alert (no false-fire)"

OUT=$(run_case open.jsonl)
contains "prune ledger idle" "$OUT" "no terminal status: idle ledger DOES alert (fires)"
lacks "integer" "$OUT" "fired path carries no arithmetic-error text"

OUT=$(run_case fresh.jsonl)
lacks "prune ledger idle" "$OUT" "fresh ledger (under 30 min): no alert"

echo
echo "== PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
