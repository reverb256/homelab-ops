#!/bin/bash
# Apply the declared .lan DNS records to a host's unbound. Diff-checked, validated.
# Usage: apply-dns.sh [host]   (default: localhost)
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)/omarchy/nexus/unbound/local-dns.conf"
HOST="${1:-}"
run() { if [ -z "$HOST" ]; then bash -c "$1"; else ssh -o ConnectTimeout=10 "$HOST" "$1"; fi; }

run "sudo cp -n /etc/unbound/local-dns.conf /etc/unbound/local-dns.conf.bak-$(date +%Y%m%d) 2>/dev/null || true"
if [ -z "$HOST" ]; then
  if diff -q "$SRC" /etc/unbound/local-dns.conf >/dev/null 2>&1; then
    echo "already in sync"; exit 0
  fi
  sudo install -m 644 "$SRC" /etc/unbound/local-dns.conf
else
  scp -q "$SRC" "$HOST:/tmp/local-dns.conf"
  run "sudo install -m 644 /tmp/local-dns.conf /etc/unbound/local-dns.conf"
fi
run "sudo unbound-checkconf >/dev/null && sudo systemctl reload unbound && echo reloaded"
