#!/bin/bash
# lan-dns-contract.sh — assert the LAN DNS contract on every fleet host.
#
# THE CONTRACT (runbook: docs/lan-dns-contract.md, t_40262b43):
#   DNS=10.1.1.53 10.1.1.100 10.1.1.120  (Pi-hole first; unbound pair = LIVE
#   secondaries in DNS= itself, NOT FallbackDNS — resolved never reads
#   FallbackDNS while any primary is set, so "DNS=.53 + FallbackDNS" was a
#   dead-Pi-hole-equals-dead-DNS trap that cost a 40-min LAN outage
#   2026-10-14, t_d47a5575).
#   No client may ever have Pi-hole as its ONLY resolver.
#
# INCIDENTS ENCODED (this check exists so neither can silently return):
#   1. 2026-10-14: dead Pi-hole stalled all lookups (FallbackDNS trap).
#   2. 2026-10-15 07:54 (t_40262b43): an agent took zephyr's wired connection
#      down during the DNS rollout; WAN gone, BOTH MINERS IDLE 1h. So after
#      any DNS/network change, a host is only "done" when its default route
#      exists, WAN answers, and the kryptex pool TCP port connects.
#   3. 2026-10-15: resolved pins to the failover server after an outage
#      (systemd #5755/#25020) — Current DNS Server sticks at 10.1.1.100 and
#      the host stays UNFILTERED while Pi-hole is healthy. Only a resolved
#      restart clears it; this check FAILS that state so it cannot linger.
#
# READ-ONLY. Needs ssh to the four hosts (BatchMode) + drill OR getent on the
# running host. Run from anywhere: `bash scripts/verify/lan-dns-contract.sh`
# (HOSTS overridable: HOSTS="nexus forge" bash ... for a subset).
set -uo pipefail

HOSTS="${HOSTS:-zephyr nexus forge sentry}"
TRIAD="10.1.1.53 10.1.1.100 10.1.1.120"
WANT_PIN="10.1.1.53"
CANARY="${CANARY:-doubleclick.net}"
POOL_HOST="${POOL_HOST:-prl-us.kryptex.network}"
POOL_PORT="${POOL_PORT:-7048}"

PASS=0; FAIL=0; INCONCLUSIVE=0
ok(){ printf 'PASS  %-58s %s\n' "$1" "$2"; PASS=$((PASS+1)); }
no(){ printf 'FAIL  %-58s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
inc(){ printf 'INCONCLUSIVE  %-52s %s\n' "$1" "$2"; INCONCLUSIVE=$((INCONCLUSIVE+1)); }

SSH="ssh -n -o ConnectTimeout=8 -o BatchMode=yes"

# Sanity: Pi-hole itself must be up, else every pin assertion is noise.
if timeout 4 drill @10.1.1.53 "$CANARY" A 2>/dev/null | grep -q "IN\s*A\s*0.0.0.0"; then
  ok "pihole .53 canary" "answers 0.0.0.0 — Pi-hole healthy"
  PH_UP=1
elif timeout 4 getent ahostsv4 "$CANARY" >/dev/null 2>&1; then
  # drill missing or pihole down: use direct getent from THIS host instead
  a=$(timeout 4 getent ahostsv4 "$CANARY" | head -1 | awk '{print $1}')
  if [ "$a" = "0.0.0.0" ]; then ok "pihole .53 canary" "0.0.0.0 (getent path)"; PH_UP=1; else no "pihole .53 canary" "unfiltered/none: $a"; PH_UP=0; fi
else
  no "pihole .53 canary" "cannot probe — drill+getent both unusable"; PH_UP=0
fi

for h in $HOSTS; do
  # 0. host reachable at all?
  if ! $SSH "$h" true 2>/dev/null; then inc "$h" "unreachable (ssh)"; continue; fi

  # 1. Global DNS list is exactly the triad (live secondaries, not FallbackDNS).
  servers=$($SSH "$h" "resolvectl status 2>/dev/null | grep -m1 'DNS Servers:' | sed 's/.*DNS Servers: //'" 2>/dev/null)
  case "$servers" in
    "$TRIAD") ok "$h global DNS list" "triad" ;;
    "")       no "$h global DNS list" "no global servers — host is resolverless"; ;;
    *)        no "$h global DNS list" "got '$servers' want '$TRIAD'"; ;;
  esac

  # 2. Pi-hole is the preferred server (failover pin must not linger).
  pin=$($SSH "$h" "resolvectl status 2>/dev/null | grep -m1 'Current DNS Server' | sed 's/.*Current DNS Server: //'" 2>/dev/null)
  if [ "$PH_UP" = 1 ]; then
    case "$pin" in
      "$WANT_PIN") ok "$h current DNS server" "10.1.1.53 (Pi-hole preferred)" ;;
      *)           no "$h current DNS server" "'$pin' — failover pin stuck (restart resolved); UNFILTERED while Pi-hole is up" ;;
    esac
  else
    inc "$h current DNS server" "Pi-hole down — pin not assertable"
  fi

  # 3. MagicDNS must not own default-route (~. = direct Pi-hole bypass, hard
  #    FAIL). A 'lan' claim on tailscale0 is tolerable ONLY while the host's
  #    global scope also claims lan (Domains=lan) so *.lan still resolves —
  #    assert the OUTCOME (.lan answers), FAIL the pairing when broken, and
  #    note the tolerated mechanism. (Correction handoff: kanban t_d47a5575
  #    comment 280 — trim should keep only tigris-ule.ts.net.)
  tsdom=$($SSH "$h" "resolvectl domain tailscale0 2>/dev/null | tail -1" 2>/dev/null)
  lan_ok=$($SSH "$h" "getent ahostsv4 nexus.lan 2>/dev/null | head -1 | awk '{print \$1}'" 2>/dev/null)
  case "$tsdom" in
    *"~."*) no "$h tailscale0 domains" "'$tsdom' — MagicDNS claims ~. (Pi-hole bypass flap)" ;;
    *) if echo "$tsdom" | grep -qE "(\s)lan(\s|$)"; then
         if [ -n "$lan_ok" ]; then
           ok "$h tailscale0 domains" "lan claim tolerated — .lan resolves via global scope"
         else
           no "$h tailscale0 domains" "lan claim AND .lan broken — add Domains=lan to global resolved.conf (see nexus) or trim lan"
         fi
       else
         ok "$h tailscale0 domains" "${tsdom:-no DNS scope on link}"
       fi ;;
  esac

  # 4. Filtered canary through the host's own path.
  a=$($SSH "$h" "getent ahostsv4 $CANARY 2>/dev/null | head -1 | awk '{print \$1}'" 2>/dev/null)
  case "$a" in
    0.0.0.0|"::") ok "$h canary $CANARY" "$a (filtered)" ;;
    "")           no "$h canary $CANARY" "no answer at all" ;;
    *)            no "$h canary $CANARY" "$a — UNFILTERED, Pi-hole bypassed" ;;
  esac

  # 5. Public + .lan still resolve (failover lives BELOW filtering, not above it).
  b=$($SSH "$h" "getent ahostsv4 github.com 2>/dev/null | head -1 | awk '{print \$1}'" 2>/dev/null)
  [ -n "$b" ] && ok "$h public DNS" "github.com -> $b" || no "$h public DNS" "no answer"
  c=$($SSH "$h" "getent ahostsv4 nexus.lan 2>/dev/null | head -1 | awk '{print \$1}'" 2>/dev/null)
  [ -n "$c" ] && ok "$h .lan DNS" "nexus.lan -> $c" || no "$h .lan DNS" "no answer — .lan broken on host"

  # 6. Connectivity (incident 2026-10-15 07:54): route + WAN + pool.
  route=$($SSH "$h" "ip route show default 2>/dev/null" 2>/dev/null)
  [ -n "$route" ] && ok "$h default route" "$(echo "$route" | head -1)" \
                   || no "$h default route" "NO DEFAULT ROUTE — WAN down (incident class)"
  if $SSH "$h" "ping -c1 -W3 1.1.1.1 >/dev/null 2>&1"; then
    ok "$h WAN probe" "1.1.1.1 answers"
  else
    no "$h WAN probe" "no WAN — host offline class"
  fi
  if $SSH "$h" "timeout 5 bash -c 'exec 3<>/dev/tcp/$POOL_HOST/$POOL_PORT' 2>/dev/null"; then
    ok "$h pool TCP $POOL_PORT" "connects (miners safe)"
  else
    no "$h pool TCP $POOL_PORT" "CANNOT CONNECT — miners at risk"
  fi
done

echo
echo "lan-dns-contract: PASS=$PASS FAIL=$FAIL INCONCLUSIVE=$INCONCLUSIVE (hosts: $HOSTS)"
if [ "$FAIL" -gt 0 ]; then exit 1
elif [ "$INCONCLUSIVE" -gt 0 ]; then exit 2
else exit 0; fi
