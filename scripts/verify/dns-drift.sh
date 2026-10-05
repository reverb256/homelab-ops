#!/bin/bash
# Drift check: is the LIVE unbound config still the DECLARED one?
#
# SRC is the SoT copy inside this checkout (omarchy/nexus/unbound/local-dns.conf), so
# this must run from a CURRENT checkout — on nexus, fleet-verify-sync.sh enforces that
# (media-k8s cluster/checks/verify-fleet.sh section 9t) before 9u runs this script.
#
# Exit: 0 = in sync, 1 = DRIFT, 2 = a peer was UNREACHABLE (INCONCLUSIVE).
#
# UNREACHABLE is deliberately a SEPARATE result. The previous version piped a failed ssh
# (empty stdout) straight into `diff`, so an unreachable host and a genuinely divergent
# config produced the identical "DRIFT on <host>". While this ran by hand that was
# survivable; on a 15-minute timer it is not — a false DRIFT every tick trains the
# operator to ignore the one that is real (kanban t_da18d37e).
#
# Overridable so the gate itself can be proven to fire AND not to false-fire:
#   DNS_DRIFT_REMOTES  space-separated peers (default: 100.105.246.35 = sentry)
#   DNS_DRIFT_LOCAL    live file on this host (default: /etc/unbound/local-dns.conf)
#   DNS_DRIFT_SRC      declared file (default: this checkout's copy)
#   DNS_DRIFT_KEY      ssh identity (default: ~/.ssh/id_ed25519_fleet)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${DNS_DRIFT_SRC:-$(cd "$HERE/../.." && pwd)/omarchy/nexus/unbound/local-dns.conf}"
LIVE="${DNS_DRIFT_LOCAL:-/etc/unbound/local-dns.conf}"
KEY="${DNS_DRIFT_KEY:-$HOME/.ssh/id_ed25519_fleet}"
REMOTES="${DNS_DRIFT_REMOTES:-100.105.246.35}"
LABEL="$(hostname)"

if [ ! -r "$SRC" ]; then
  echo "INCONCLUSIVE: declared file absent: $SRC (run from a current homelab-ops checkout)"
  exit 2
fi

drift=0        # 1 once a real difference is seen
unreachable=0  # 1 once a peer cannot be read

check_local() {
  if [ ! -r "$LIVE" ]; then
    echo "UNREACHABLE on $LABEL ($LIVE unreadable)"
    unreachable=1
    return 0
  fi
  diff -q "$SRC" "$LIVE" >/dev/null 2>&1 || { echo "DRIFT on $LABEL"; drift=1; }
}

check_remote() { # $1 = host
  local host="$1" live rc
  live=$(ssh -o ConnectTimeout=8 -o BatchMode=yes -i "$KEY" "$host" 'cat /etc/unbound/local-dns.conf' 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "UNREACHABLE on $host (ssh rc=$rc)"
    unreachable=1
    return 0
  fi
  diff -q "$SRC" - <<<"$live" >/dev/null 2>&1 || { echo "DRIFT on $host"; drift=1; }
}

check_local
for host in $REMOTES; do check_remote "$host"; done

if [ "$drift" = 1 ]; then
  exit 1
fi
if [ "$unreachable" = 1 ]; then
  echo "INCONCLUSIVE: DNS in sync on $LABEL, but a peer could not be read"
  exit 2
fi
echo "OK: DNS in sync on $LABEL + $REMOTES"
exit 0
