#!/usr/bin/env bash
# Sync the canonical default-profile SOUL.md to its host(s).
# Canonical: homelab-ops/hermes/SOUL.md. Live target: zephyr ~/.hermes/SOUL.md.
# The other hosts' default profiles intentionally keep the stock SOUL (their
# role agents carry the custom identities; watchdog skips */default/*).
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)/SOUL.md"
HOST="${1:-zephyr}"
if [ "$HOST" = "zephyr" ]; then
  cp "$SRC" "$HOME/.hermes/SOUL.md"
else
  scp -q "$SRC" "$HOST:~/.hermes/SOUL.md"
fi
wc -c "$SRC"
grep -c "OPERATING TRIGGERS\|ACT-DIRECTLY LAW\|FAILURE -> TEST" "$SRC"
echo "SOUL synced to $HOST"
