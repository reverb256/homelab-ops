#!/usr/bin/env bash
# test-k3s-boot-units.sh — the ordering-cycle gate must fire, and must not false-fire.
#
# What this pins (kanban t_8aebe4fa; each assertion is a real failure mode):
#   A check that never fires is indistinguishable from a fixed one. The 2026-10-16
#   defect was silent by construction: systemd DELETED the etcd mount's start job to
#   break an ordering cycle, so the boot succeeded with k3s never started and nothing
#   went red. Two fixtures therefore run the REAL scripts/verify/k3s-boot-units.sh
#   with sections C-E skipped (they describe THIS boot, not a drilled unit copy):
#     broken : the exact 240-byte unit file from before the fix (sha256 23dc99e830b4…,
#              After=local-fs.target + WantedBy=local-fs.target, default dependencies)
#              -> must FAIL with "CYCLIC" and the cycle lines systemd printed at 15:02:30
#     fixed  : the unit as committed in omarchy/nexus/systemd/
#              -> must PASS ("RESULT: OK") — a gate that fires on everything is noise
#   The gate is proven against COPIES, so the live host's units are never touched and
#   this test is safe to run on a healthy host (it does not need /etc/systemd/system,
#   a reboot, or a broken fleet to be meaningful).
#
# Run on nexus:  bash tests/test-k3s-boot-units.sh
# Test another revision:
#   K3S_BOOT_SCRIPT=/path/to/k3s-boot-units.sh bash tests/test-k3s-boot-units.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHK="${K3S_BOOT_SCRIPT:-$ROOT/scripts/verify/k3s-boot-units.sh}"
UNIT="$ROOT/omarchy/nexus/systemd/var-lib-rancher-k3s-server-db-etcd.mount"
PASS=0 FAIL=0
ok(){ printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
contains(){ printf '%s' "$2" | grep -qF -- "$1" && ok "$3" || no "$3 (missing: $1)"; }

[ -x "$CHK" ]  && ok "script under test is executable ($CHK)" || no "script under test missing: $CHK"
[ -f "$UNIT" ] && ok "committed unit found ($UNIT)"            || no "committed unit missing: $UNIT"

if ! command -v systemd-analyze >/dev/null 2>&1; then
  echo "SKIP: systemd-analyze not installed — the static gate cannot be exercised here"
  echo; echo "== PASS=$PASS FAIL=$FAIL =="
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fixed" "$TMP/broken"
cp "$UNIT" "$TMP/fixed/var-lib-rancher-k3s-server-db-etcd.mount"
cp "$UNIT" "$TMP/broken/var-lib-rancher-k3s-server-db-etcd.mount"

# Regress the fix into the fixture: strip the committed [Unit] ordering down to the
# pre-fix shape (default dependencies + After=local-fs.target), keeping the same
# [Mount]/[Install] so the only difference is the ordering that caused the incident.
{
  printf '[Unit]\n'
  grep -E '^Description=' "$UNIT"
  printf 'RequiresMountsFor=/data/fast\nAfter=local-fs.target\n'
  sed -n '/^\[Mount\]/,$p' "$UNIT"
} > "$TMP/broken/unit.new" && mv "$TMP/broken/unit.new" "$TMP/broken/var-lib-rancher-k3s-server-db-etcd.mount"
contains "After=local-fs.target" "$(cat "$TMP/broken/var-lib-rancher-k3s-server-db-etcd.mount")" \
  "broken fixture carries the pre-fix ordering (After=local-fs.target)"

run(){ # $1 = dir under test
  K3S_BOOT_UNITS=var-lib-rancher-k3s-server-db-etcd.mount \
  K3S_BOOT_SCAN_ROOT="$1" K3S_BOOT_SKIP_RUNTIME=1 \
    bash "$CHK" 2>&1
}

OUT=$(run "$TMP/broken"); RC=$?
contains "CYCLIC" "$OUT" "pre-fix unit: the gate FIRES (boot transaction is cyclic)"
contains "deleted to break ordering cycle" "$OUT" "pre-fix unit: the failure text names the deleted start job"
[ "$RC" -eq 1 ] && ok "pre-fix unit: exit 1 (FAIL)" || no "pre-fix unit: expected rc=1, got rc=$RC"

OUT=$(run "$TMP/fixed"); RC=$?
contains "RESULT: OK" "$OUT" "committed unit: the gate holds (no false-fire)"
[ "$RC" -eq 0 ] && ok "committed unit: exit 0 (OK)" || no "committed unit: expected rc=0, got rc=$RC"
if printf '%s' "$(grep -v '^#' "$UNIT")" | grep -qE '^After=local-fs\.target'; then
  no "committed unit still declares After=local-fs.target (the cycle)"
else
  ok "committed unit: no After=local-fs.target directive in [Unit]"
fi

echo
echo "== PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
