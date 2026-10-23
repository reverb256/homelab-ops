#!/usr/bin/env bash
# Install stale-reaper + hermes-job on a Linux host and enable the timer.
# Idempotent. Run on each host: bash install-stale-reaper.sh [--dry-run]
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
DRY=${1:-}

run() { if [[ $DRY == --dry-run ]]; then echo "[dry] $*"; else "$@"; fi; }

# linger must be on, or the user timer dies with the last login session
if [[ $(loginctl show-user "$USER" -p Linger --value) != yes ]]; then
  echo "enabling linger for $USER (needs sudo)" >&2
  run sudo loginctl enable-linger "$USER"
fi

run install -Dm755 "$here/../../bin/stale-reaper" "$HOME/.local/bin/stale-reaper"
run install -Dm755 "$here/../../bin/hermes-job" "$HOME/.local/bin/hermes-job"
run install -Dm644 "$here/systemd/stale-reaper.service" "$HOME/.config/systemd/user/stale-reaper.service"
run install -Dm644 "$here/systemd/stale-reaper.timer" "$HOME/.config/systemd/user/stale-reaper.timer"

run install -d -m755 "$HOME/.config/stale-reaper"
if [[ $DRY == --dry-run ]]; then
  echo "[dry] would seed $HOME/.config/stale-reaper/keep if missing"
elif [[ ! -f $HOME/.config/stale-reaper/keep ]]; then
  cat >"$HOME/.config/stale-reaper/keep" <<'EOF'
# stale-reaper keep list: one extended regex per line, matched against the
# process cmdline. A match protects that process and its whole process tree.
# Example: ^/usr/bin/blender .*/projects/commission-2026
EOF
  echo "created $HOME/.config/stale-reaper/keep"
fi

run systemctl --user daemon-reload
run systemctl --user enable --now stale-reaper.timer
run systemctl --user list-timers stale-reaper.timer --no-pager
echo "ok: $(hostname)"
