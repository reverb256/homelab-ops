#!/bin/bash
# repin-resolved.sh — restore Pi-hole as the PREFERRED resolver after a failover.
#
# WHY THIS EXISTS (t_40262b43): systemd-resolved sticks to the first server that
# answered after a failover and does NOT return to the head of the list on its own
# (systemd issues #5755 / #25020 — upstream WONTFIX "dumb mode"). So after any
# Pi-hole outage, every host keeps resolving via unbound (10.1.1.100) and the LAN
# is silently UNFILTERED even though Pi-hole is back. The only way to clear the
# learned state is to restart systemd-resolved (config reapply does not reset it).
#
# Incident 2026-10-15 07:54 (zephyr WAN down, miners idle 1h) adds hard rules,
# enforced below: after touching a host's resolver we MUST prove
#   (1) the default route still exists via the intended interface,
#   (2) WAN reachability (ping 1.1.1.1),
#   (3) the mining pool TCP port still connects,
#   (4) DNS answers again, Pi-hole preferred.
# The script exits nonzero on any failure. Never leaves a connection 'down'.
set -uo pipefail

HOST="${1:-localhost}"
TRIAD="10.1.1.53 10.1.1.100 10.1.1.120"
WANT_PIN="10.1.1.53"          # Pi-hole must be Current DNS Server when it answers
CANARY=doubleclick.net
POOL_HOST=prl-us.kryptex.network
POOL_PORT=7048

fail=0
ok(){ printf 'PASS  %-46s %s\n' "$1" "$2"; }
no(){ printf 'FAIL  %-46s %s\n' "$1" "$2"; fail=1; }

if [ "$HOST" = "localhost" ]; then SSH=""; else SSH="ssh -n -o ConnectTimeout=8 -o BatchMode=yes $HOST"; fi

# 0. Config must already be the triad BEFORE we restart anything.
servers=$($SSH resolvectl status 2>/dev/null | grep -m1 'DNS Servers:' | sed 's/.*DNS Servers: //')
case "$servers" in
  "10.1.1.53 10.1.1.100 10.1.1.120") ok "$HOST global DNS list" "triad confirmed" ;;
  *) no "$HOST global DNS list" "got '$servers' — fix resolved.conf/drop-in first"; exit 1 ;;
esac

# 1. Restart resolved to clear the learned server state.
$SSH sudo -n systemctl restart systemd-resolved
sleep 2
# Cache from probes done mid-failover can mask the restored path — start clean.
$SSH sudo -n resolvectl flush-caches 2>/dev/null || true

# 2. Pi-hole must be the current server again.
pin=$($SSH resolvectl status 2>/dev/null | grep -m1 'Current DNS Server' | sed 's/.*Current DNS Server: //')
case "$pin" in
  "$WANT_PIN") ok "$HOST current DNS server" "$pin (Pi-hole preferred)" ;;
  *) no "$HOST current DNS server" "'$pin' — expected $WANT_PIN" ;;
esac

# 3. Route + WAN + pool (incident 2026-10-15 requirements).
route=$($SSH ip route show default 2>/dev/null | head -1)
case "$route" in
  *"dev enp"*|*"dev eno"*|*"dev eth"*) ok "$HOST default route" "$route" ;;
  "") no "$HOST default route" "NO DEFAULT ROUTE — connectivity broken" ;;
  *) no "$HOST default route" "unexpected: $route" ;;
esac

if $SSH ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then ok "$HOST WAN probe" "1.1.1.1 answers"; else no "$HOST WAN probe" "ping 1.1.1.1 failed"; fi
if $SSH timeout 5 bash -c "exec 3<>/dev/tcp/${POOL_HOST}/${POOL_PORT}" 2>/dev/null; then
  ok "$HOST pool TCP ${POOL_PORT}" "connects"
else
  no "$HOST pool TCP ${POOL_PORT}" "cannot connect — MINERS AT RISK"
fi

# 4. DNS battery: filtered canary, public name, .lan name.
a=$($SSH getent ahostsv4 $CANARY 2>/dev/null | head -1 | awk '{print $1}')
case "$a" in
  0.0.0.0|"::") ok "$HOST canary $CANARY" "$a (filtered — Pi-hole path live)" ;;
  "") no "$HOST canary $CANARY" "no answer" ;;
  *) no "$HOST canary $CANARY" "$a — UNFILTERED, Pi-hole bypassed" ;;
esac
b=$($SSH getent ahostsv4 github.com 2>/dev/null | head -1 | awk '{print $1}')
[ -n "$b" ] && ok "$HOST public DNS" "github.com -> $b" || no "$HOST public DNS" "no answer"
c=$($SSH getent ahostsv4 nexus.lan 2>/dev/null | head -1 | awk '{print $1}')
[ -n "$c" ] && ok "$HOST .lan DNS" "nexus.lan -> $c" || no "$HOST .lan DNS" "no answer"

[ "$fail" -eq 0 ] && echo "RESULT $HOST: ALL PASS" || echo "RESULT $HOST: FAILURES PRESENT"
exit $fail
