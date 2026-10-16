#!/usr/bin/env bash
# scripts/verify/k3s-boot-units.sh — can the boot transaction still start k3s?
#
# INCIDENT 2026-10-16 (kanban t_8aebe4fa; this script is its regression check):
#   /etc/systemd/system/var-lib-rancher-k3s-server-db-etcd.mount carried BOTH
#   `After=local-fs.target` and `[Install] WantedBy=local-fs.target`. A .mount with
#   default dependencies ALREADY gets an implicit `Before=local-fs.target`, so the
#   explicit After= made the pair cyclic. systemd resolves such a cycle by DELETING
#   the mount's start job, so /var/lib/rancher/k3s/server/db/etcd was never mounted
#   and k3s.service — which requires it (k3s.service.d/30-etcd-fasttier.conf:
#   RequiresMountsFor) — was silently never started. Nothing FAILED: no unit went
#   red, no alert fired, the boot "succeeded". Node nexus just vanished from the
#   cluster ("Kubelet stopped posting node status") until a human noticed, and every
#   pod pinned to it (the music-pipeline render rail, the media stack) could not
#   start. Back then it was found only because music card t_b8afb055 could not run
#   its in-cluster render Job. Recovery was a manual `systemctl start k3s`
#   (15:05:58 on a 15:02:08 boot, NRestarts=0, node NotReady 15:01-15:05).
#
# Why the checks are shaped this way: a reboot is a terrible way to test a boot.
# systemd will build the very transaction that failed, offline, and say so:
#     systemd-analyze verify <unit> local-fs.target
# prints "Found ordering cycle: ..." / "Job .../start deleted to break ordering
# cycle" / "Failed to create local-fs.target/start: Transaction order is cyclic"
# on the broken unit file (measured: 5 matching lines, and 0 on the fixed one).
# That is section A — it fires WITHOUT a reboot, on a COPY of the unit (so the gate
# can be proven to fire without touching the live file). Section B is the same
# defect class reduced to a property of one unit's own graph: a target that the
# unit is WantedBy AND ordered After is a cycle by construction (measured across
# all 22 /etc/systemd/system/*.mount on nexus: exactly one offender, the etcd
# mount; zero false positives). Sections C-E are the post-boot alarm for boots
# that already happened.
#
# Read-only: systemctl show/is-active, systemd-analyze verify, journalctl, findmnt,
# `kubectl get`. Nothing is written, enabled, started, restarted or unmounted.
#
# HOST: nexus (the only host carrying fast-tier bind mounts; on sentry/forge the
#       static sections report INCONCLUSIVE, not a false PASS).
# Exit: 0 = OK, 1 = FAIL, 2 = INCONCLUSIVE.
# Overrides (so the gate can be proven to fire AND not to false-fire):
#   K3S_BOOT_UNITS        space-separated unit names or absolute paths to verify
#                         (default: the two k3s fast-tier binds on nexus)
#   K3S_BOOT_TARGET       target the boot transaction is built against (local-fs.target)
#   K3S_BOOT_SCAN_ROOT    dir of *.mount units swept for the cycle property
#                         (default /etc/systemd/system)
#   K3S_BOOT_SKIP_RUNTIME 1 = static sections only (used by the drill: the runtime
#                         sections describe THIS boot, not a drilled unit copy)
#   K3S_UNIT              k3s unit (default k3s)
#   K3S_NODE              node that must be Ready (default: local hostname)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$HERE/_lib.sh"

UNITS="${K3S_BOOT_UNITS:-var-lib-rancher-k3s-server-db-etcd.mount var-lib-rancher-k3s-agent-containerd.mount}"
TARGET="${K3S_BOOT_TARGET:-local-fs.target}"
SCAN_ROOT="${K3S_BOOT_SCAN_ROOT:-/etc/systemd/system}"
K3S_UNIT="${K3S_UNIT:-k3s}"
K3S_NODE="${K3S_NODE:-$(hostname -s)}"
SKIP_RUNTIME="${K3S_BOOT_SKIP_RUNTIME:-0}"
# Tolerated boot->active delta for the k3s note below. The 2026-10-16 incident's
# manual start landed 230s after boot, i.e. inside legitimate restart noise, which
# is why this is a note and not a verdict: sections A/B are the detectors.
BOOT_GRACE_S="${K3S_BOOT_GRACE_S:-300}"

echo "verify/k3s-boot-units.sh  host=$(hostname)  $(date '+%Y-%m-%d %H:%M:%S%z')"
echo "  units='$UNITS'  target=$TARGET  k3s=$K3S_UNIT  node=$K3S_NODE"
echo "  read-only: the boot transaction is re-built offline; nothing is started or restarted"
_hr

# ── A. the boot transaction builds: no ordering cycle in the fast-tier units ───
# systemd-analyze verify constructs a transaction for the named units + target and
# prints the cycle it would break. This is the check that would have caught the
# 2026-10-16 defect while the host was UP, without a reboot.
section "A. boot transaction builds (no cycle in $TARGET)"
if ! command -v systemd-analyze >/dev/null 2>&1; then
  inconclusive "systemd-analyze not found — cannot re-build the transaction offline"
else
  A_ANY=0
  for u in $UNITS; do
    case "$u" in
      /*) PATHNAME="$u" ;;
      *)  PATHNAME="$SCAN_ROOT/$u" ;;
    esac
    if [ ! -f "$PATHNAME" ]; then
      inconclusive "$u: no unit file at $PATHNAME (not installed on this host)"
      continue
    fi
    A_ANY=1
    VOUT="$(systemd-analyze verify "$PATHNAME" "$TARGET" 2>&1)"
    VCYC="$(printf '%s\n' "$VOUT" | grep -ci 'ordering cycle\|cyclic')"
    if [ "${VCYC:-0}" -gt 0 ]; then
      check 1 "$u: the boot transaction for $TARGET is CYCLIC — systemd will delete a start job (sha256 $(sha256sum "$PATHNAME" | cut -c1-12))"
      printf '%s\n' "$VOUT" | grep -i 'ordering cycle\|cyclic' | sed 's/^/         /' | head -4
    else
      check 0 "$u: verify($TARGET) reports no ordering cycle (sha256 $(sha256sum "$PATHNAME" | cut -c1-12))"
    fi
  done
  [ "$A_ANY" -eq 1 ] || inconclusive "none of the units exist here — nothing was verified"
fi

# ── B. class sweep: no .mount may be WantedBy a target it is also After ────────
# The 2026-10-16 defect in one line: `WantedBy=local-fs.target` + `After=local-fs.target`.
# Purely local to each unit, so it generalises to every managed mount, including ones
# added later by apply.sh.
section "B. no mount is wanted-by a target it starts after ($SCAN_ROOT)"
B_SCANNED=0
B_BAD=""
for f in "$SCAN_ROOT"/*.mount; do
  [ -f "$f" ] || continue
  u="$(basename "$f")"
  B_SCANNED=$((B_SCANNED + 1))
  W="$(systemctl show -p WantedBy --value "$u" 2>/dev/null)"
  [ -n "$W" ] || continue
  A_LIST=" $(systemctl show -p After --value "$u" 2>/dev/null) "
  for t in $W; do
    case "$A_LIST" in
      *" $t "*) B_BAD="$B_BAD $u($t)" ;;
    esac
  done
done
assert_nonempty "mount units scanned under $SCAN_ROOT" "$B_SCANNED" >/dev/null \
  || printf '  [INCONCLUSIVE] no *.mount units under %s — a clean sweep here is meaningless\n' "$SCAN_ROOT"
if [ "$B_SCANNED" -gt 0 ]; then
  if [ -z "$B_BAD" ]; then
    check 0 "$B_SCANNED mount unit(s): WantedBy and After never name the same target (no cycle by construction)"
  else
    check 1 "WantedBy=target AND After=target (ordering cycle) in:$B_BAD"
  fi
fi

if [ "$SKIP_RUNTIME" = "1" ]; then
  note "K3S_BOOT_SKIP_RUNTIME=1 — sections C-E (this boot's journal/k3s/node) skipped"
  finish
fi

# ── C. no *unexplained* ordering cycle in this boot's journal ─────────────────
# The post-boot alarm. Judged carefully, because the journal for a boot survives
# until the next reboot: the 2026-10-16 boot keeps reporting its cycle for the rest
# of the day even though the unit was fixed minutes later, and an alarm that cannot
# clear is noise, not a detector. So a cycle line FAILs only when at least one unit
# it names is still the unit that was in place at that boot (`mtime <= boot`); when
# every unit named in it was (re)installed AFTER that boot, the cycle is stale and
# is reported as a note that names the boot. Either way the journal lines print.
section "C. this boot's journal reports no ordering cycle"
if ! command -v journalctl >/dev/null 2>&1; then
  inconclusive "journalctl not found"
else
  JLINES="$(journalctl -b --no-pager 2>/dev/null | wc -l)"
  if ! assert_nonempty "journalctl -b" "$JLINES"; then
    :
  else
    CYC="$(journalctl -b --no-pager 2>/dev/null | grep -i 'ordering cycle' || true)"
    if [ -z "$CYC" ]; then
      check 0 "no 'ordering cycle' line in $(printf '%s' "$JLINES") journal lines for this boot"
    else
      BOOT_TS="$(date -d "$(uptime -s)" +%s 2>/dev/null || echo 0)"
      C_STALE=1; C_SEEN=""; C_LATE=""
      for cu in $(printf '%s\n' "$CYC" | grep -oE '[A-Za-z0-9@_.\\-]+\.(mount|service|target|socket)' | sort -u); do
        cf="$SCAN_ROOT/$cu"
        [ -f "$cf" ] || continue
        C_SEEN="$C_SEEN $cu"
        CM="$(stat -c %Y "$cf" 2>/dev/null || echo 0)"
        if [ "$CM" -le "$BOOT_TS" ]; then
          C_STALE=0
        else
          C_LATE="$C_LATE $cu(+$(( (CM - BOOT_TS) / 60 ))min)"
        fi
      done
      if [ "$C_STALE" = "1" ] && [ -n "$C_SEEN" ]; then
        note "STALE ALARM (not a FAIL): this boot reported a cycle, but every unit it names was (re)installed after that boot:$C_LATE — it clears at the next reboot"
        printf '%s\n' "$CYC" | sed 's/^/         /' | head -3
      else
        check 1 "$(printf '%s\n' "$CYC" | wc -l) 'ordering cycle' line(s) this boot, still unexplained by a later unit change — a start job was deleted"
        printf '%s\n' "$CYC" | sed 's/^/         /' | head -4
      fi
    fi
  fi
fi

# ── D. the fast-tier binds are mounted and k3s is up ──────────────────────────
section "D. fast-tier binds mounted, $K3S_UNIT active"
for u in $UNITS; do
  name="$(basename "$u")"
  if ! systemctl show "$name" >/dev/null 2>&1; then
    inconclusive "$name: not loaded on this host"
    continue
  fi
  state="$(systemctl is-active "$name" 2>/dev/null)"
  where="$(systemctl show -p Where --value "$name" 2>/dev/null)"
  if [ "$state" = "active" ]; then
    check 0 "$name is active"
  else
    check 1 "$name is '$state' — if its start job was deleted, the etcd path is NOT mounted and k3s cannot start"
  fi
  if [ -z "$where" ]; then
    inconclusive "$name: no Where= to check"
  elif ! command -v findmnt >/dev/null 2>&1; then
    inconclusive "$name: findmnt not found, cannot check $where"
  elif findmnt -M "$where" >/dev/null 2>&1; then
    check 0 "$where is a mountpoint ($(findmnt -M "$where" -no SOURCE 2>/dev/null))"
  else
    # NOTE: do NOT use `mountpoint -q` here. Measured 2026-10-16: it returns 1 for
    # these /data/fast binds (a bind of a subdirectory keeps its source's st_dev,
    # which `mountpoint` reads as "not a mount root") while findmnt -M returns 0.
    # The false negative would have made this check lie in the other direction.
    check 1 "$where is NOT a mountpoint (systemd reports $name=$state)"
  fi
done

KSTATE="$(systemctl is-active "$K3S_UNIT" 2>/dev/null || true)"
if [ -z "$KSTATE" ]; then
  inconclusive "systemctl is-active $K3S_UNIT returned nothing (unit not present?)"
elif [ "$KSTATE" = "active" ]; then
  check 0 "$K3S_UNIT is active"
else
  check 1 "$K3S_UNIT is '$KSTATE' — the cluster node is gone until someone starts it by hand"
fi
if [ "$KSTATE" = "active" ]; then
  BOOT_TS="$(date -d "$(uptime -s)" +%s 2>/dev/null || echo "")"
  K3S_TS="$(date -d "$(systemctl show -p ActiveEnterTimestamp --value "$K3S_UNIT" 2>/dev/null)" +%s 2>/dev/null || echo "")"
  if [ -n "$BOOT_TS" ] && [ -n "$K3S_TS" ] && [ "$K3S_TS" -gt "$BOOT_TS" ]; then
    DELTA=$((K3S_TS - BOOT_TS))
    if [ "$DELTA" -gt "$BOOT_GRACE_S" ]; then
      note "NOTE: $K3S_UNIT became active ${DELTA}s after this boot — the boot transaction did not start it (deliberate restart, or the 2026-10-16 class: a human started it by hand)"
    else
      note "$K3S_UNIT became active ${DELTA}s after this boot"
    fi
  fi
fi

# ── E. the node this host runs is actually Ready in the cluster ───────────────
section "E. node $K3S_NODE has a True Ready condition"
if ! command -v kubectl >/dev/null 2>&1; then
  inconclusive "kubectl not on PATH"
else
  NREP="$(kubectl get node "$K3S_NODE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>&1)"
  if [ "$NREP" = "True" ]; then
    check 0 "node $K3S_NODE Ready=True"
  elif [ -z "$NREP" ]; then
    check 1 "node $K3S_NODE has no Ready condition (kubectl returned nothing) — the node object is gone/unknown"
  else
    check 1 "node $K3S_NODE Ready=$NREP — $(kubectl get node "$K3S_NODE" -o jsonpath='{range .status.conditions[*]}{.reason} {end}' 2>/dev/null)"
  fi
fi

finish
