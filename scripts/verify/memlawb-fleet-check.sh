#!/usr/bin/env bash
# memlawb fleet check — regression gate for the 2026-10-03 incident.
#
# Incident: per-profile memlawb plugin dirs were plain COPIES of the provider
# package, not symlinks. Copies break the provider's sys.path bootstrap
# (dirname(dirname(realpath(__file__))) has no memlawb_provider/ sibling), so
# load_memory_provider('memlawb') returned None for every profile. Separately,
# memory.memlawb.{url,namespace} was inert at runtime — the loader never
# passed the config block — so per-profile namespaces silently no-op'd.
#
# This check catches both classes, per host:
#   1. server health
#   2. passphrase file present + 0600
#   3. every profiles/*/plugins/memlawb is a SYMLINK (not a copy)
#   4. load probe: provider loads and resolves the namespace from config
#
# Usage: bash scripts/verify/memlawb-fleet-check.sh   (from anywhere; run on zephyr)
set -u
FAIL=0
ok()  { printf '  [ok]   %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=1; }

echo "== memlawb fleet check ($(date -Is)) =="

H=$(curl -s -m 6 http://100.76.105.73:8080/health || true)
case "$H" in
  *'"ok":true'*) ok "server health (:8080)";;
  *) bad "server health: $H";;
esac

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/memlawb_probe.py" <<'PYEOF'
import sys, os
root = sys.argv[1]
sys.path.insert(0, root)
from plugins.memory import load_memory_provider as L
p = L("memlawb", register_skills=False)
print((p._namespace if p else "LOAD-FAIL"), "|",
      ("avail" if p and p.is_available() else "unavail"))
PYEOF

check_host() {
  local host="$1" pyroot="$2" pypath="$3" probe_profile="$4"
  echo "-- $host"
  if ssh -o ConnectTimeout=10 "$host" 'test -f ~/.memlawb-passphrase.txt && [ "$(stat -c %a ~/.memlawb-passphrase.txt)" = "600" ]' 2>/dev/null; then
    ok "$host passphrase 0600"
  else
    bad "$host passphrase missing or wrong perms"
  fi
  local links bad_dirs
  links=$(ssh -o ConnectTimeout=10 "$host" 'for d in ~/.hermes/profiles/*/plugins/memlawb; do [ -e "$d" ] || continue; n=$(basename "$(dirname "$(dirname "$d")")"); if [ -L "$d" ]; then echo "S $n"; else echo "B $n"; fi; done' 2>/dev/null)
  bad_dirs=$(echo "$links" | awk '$1=="B"{print $2}' | tr '\n' ' ')
  if [ -n "$bad_dirs" ]; then
    bad "$host non-symlink plugin dirs: $bad_dirs"
  else
    ok "$host: all plugin dirs are symlinks ($(echo "$links" | grep -c '^S ') profiles)"
  fi
  scp -q "$TMP/memlawb_probe.py" "$host:/tmp/memlawb_probe.py" 2>/dev/null
  local out
  out=$(ssh -o ConnectTimeout=10 "$host" "HERMES_HOME=\$HOME/.hermes/profiles/$probe_profile $pypath /tmp/memlawb_probe.py $pyroot" 2>/dev/null)
  case "$out" in
    *avail*) ok "$host probe ($probe_profile): $out";;
    *) bad "$host probe ($probe_profile): $out";;
  esac
}

check_host zephyr /home/j_kro/.hermes/hermes-agent /home/j_kro/.hermes/hermes-agent/venv/bin/python analyst
check_host nexus  /opt/hermes-agent               /opt/hermes-agent/venv/bin/python           analyst

echo
if [ "$FAIL" = 0 ]; then echo "MEMLAWB FLEET CHECK PASS"; else echo "MEMLAWB FLEET CHECK FAIL"; fi
exit "$FAIL"
