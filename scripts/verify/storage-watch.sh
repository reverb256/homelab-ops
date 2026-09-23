#!/usr/bin/env bash
# Launcher: the canonical watchdog lives in homelab-ops (one source of truth).
# Kept as a real file (not a symlink) because the cron CLI refuses paths that
# resolve outside ~/.hermes/scripts/ by traversal guard.
exec /home/j_kro/homelab-ops/scripts/verify/storage-watch.sh "$@"
