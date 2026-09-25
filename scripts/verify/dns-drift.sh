#!/bin/bash
# Drift check: is the live unbound config still the declared one?
SRC="$(cd "$(dirname "$0")/../.." && pwd)/omarchy/nexus/unbound/local-dns.conf"
ok=1
for H in "" "100.105.246.35"; do
  if [ -z "$H" ]; then
    diff -q "$SRC" /etc/unbound/local-dns.conf >/dev/null 2>&1 || { echo "DRIFT on nexus"; ok=0; }
  else
    ssh -o ConnectTimeout=8 "$H" "cat /etc/unbound/local-dns.conf" 2>/dev/null | diff -q "$SRC" - >/dev/null 2>&1 \
      || { echo "DRIFT on $H"; ok=0; }
  fi
done
[ "$ok" = 1 ] && echo "OK: DNS in sync on nexus + sentry"
exit $((1-ok))
