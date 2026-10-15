#!/bin/bash
# apply-resolved-dropins.sh <host> [<host> ...]
#
# Install the committed systemd-resolved drop-ins (omarchy/<host>/etc/systemd/
# resolved.conf.d/) onto one or more hosts and restart systemd-resolved.
# Idempotent: a host whose files already match is skipped, restart included.
#
# WHY THIS EXISTS (kanban t_d47a5575, incident 2026-10-14 14:15-14:55 CDT):
# the LAN's DNS contract is "pihole primary + LIVE unbound secondaries"
# (see omarchy/<host>/etc/systemd/resolved.conf.d/50-pihole.conf). Without an
# applier, drift-check D9 can only report the drop-ins as drifted — the file
# that keeps the LAN's DNS from ever again stalling on a dead Pi-hole had no
# repair path. The 50-pihole.conf drop-ins are the HOST layer; the kubelet
# layer (pods) is scripts/apply-k3s-resolv-conf.sh — a different applier,
# different risk profile (k3s restart), do not mix them.
#
# NOTE for zephyr and sentry (Omarchy desktops): /usr/sbin/omarchy-dns owns
# the resolved MAIN file and all NetworkManager DNS layers there. Do NOT edit
# /etc/systemd/resolved.conf or NM profiles by hand on those hosts — run
# `omarchy dns Custom` with "10.1.1.53 10.1.1.100 10.1.1.120" instead, then
# re-run this script for the drop-ins. A DNS= list in a drop-in on those hosts
# would fight the tool (main-file entries accumulate AHEAD of drop-ins).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ "$#" -ge 1 ] || { echo "usage: $0 <host> [<host> ...]" >&2; exit 1; }

for HOST in "$@"; do
  DIR="$ROOT/omarchy/$HOST/etc/systemd/resolved.conf.d"
  if [ ! -d "$DIR" ] || [ -z "$(ls -A "$DIR" 2>/dev/null)" ]; then
    echo "== $HOST: no committed resolved drop-ins (nothing to do)"
    continue
  fi
  echo "== $HOST"
  CHANGED=0
  for f in "$DIR"/*.conf; do
    BASE="$(basename "$f")"
    if ssh -o ConnectTimeout=10 "$HOST" "cmp -s /etc/systemd/resolved.conf.d/$BASE -" < "$f" 2>/dev/null; then
      echo "  ok: $BASE (unchanged)"
      continue
    fi
    ssh -o ConnectTimeout=10 "$HOST" "sudo -n cp -a /etc/systemd/resolved.conf.d/$BASE /etc/systemd/resolved.conf.d/$BASE.bak-\$(date +%Y%m%d%H%M%S) 2>/dev/null || true"
    ssh -o ConnectTimeout=10 "$HOST" "install -m 644 /dev/stdin /tmp/$BASE" < "$f"
    ssh -o ConnectTimeout=10 "$HOST" "sudo -n install -m 644 /tmp/$BASE /etc/systemd/resolved.conf.d/$BASE && rm -f /tmp/$BASE"
    echo "  set: $BASE"
    CHANGED=1
  done
  if [ "$CHANGED" = 0 ]; then
    echo "  no change -> not restarting systemd-resolved (idempotent)"
  else
    echo "  restarting systemd-resolved ..."
    ssh -o ConnectTimeout=10 "$HOST" "sudo -n systemctl restart systemd-resolved && sleep 2 && systemctl is-active systemd-resolved"
    ssh -o ConnectTimeout=10 "$HOST" "resolvectl dns | head -2"
  fi
done

echo
echo "Verify after applying (battery: global triad, canary 0.0.0.0, github):"
echo "  runbooks/pihole-dns-failover-2026-10-15.md § verify"
