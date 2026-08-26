#!/usr/bin/env bash
# Apply zephyr's Omarchy system config: modprobe overrides, miner units, drop-ins.
#
# Idempotent. Re-run to reconcile drift. Run from zephyr or on zephyr itself.
#
#   ./apply.sh --check     dry run, show what would change, touch nothing
#   ./apply.sh             apply
#
# Requires root on zephyr (sudo).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
act()  { if (( CHECK )); then printf '  would: %s\n' "$*"; else eval "$*"; fi; }

[[ "$(hostname)" == "zephyr" ]] || die "run this on zephyr (current host: $(hostname))"

if (( ! CHECK )) && [[ $EUID -ne 0 ]]; then
  sudo -n true 2>/dev/null || die "need root. Passwordless sudo is not configured on zephyr — run: sudo $0 ${*:-}"
fi
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

CHANGED=0

install_file() {
  local src="$1" dst="$2" mode="${3:-0644}"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    printf '  ok: %s (unchanged)\n' "$dst"
    return 0
  fi
  act "$SUDO install -Dm$mode '$src' '$dst'"
  printf '  set: %s\n' "$dst"
  CHANGED=1
}

# ── 1. modprobe.d ──────────────────────────────────────────────────────────
log "modprobe.d overrides"

for f in "$REPO_DIR"/modprobe.d/*.conf; do
  install_file "$f" "/etc/modprobe.d/$(basename "$f")"
done

# ── 2. systemd units ──────────────────────────────────────────────────────
log "systemd units"

# miner units
for unit in "$REPO_DIR"/systemd/peakminer-*.service; do
  install_file "$unit" "/etc/systemd/system/$(basename "$unit")"
done

# drop-ins
for d in "$REPO_DIR"/systemd/*/; do
  name="$(basename "$d")"              # e.g. docker.service.d
  for f in "$d"*.conf; do
    install_file "$f" "/etc/systemd/system/$name/$(basename "$f")"
  done
done

# ── 3. daemon-reload + enable miners ──────────────────────────────────────
if (( ! CHECK )); then
  act "$SUDO systemctl daemon-reload"
  for unit in "$REPO_DIR"/systemd/peakminer-*.service; do
    name="$(basename "$unit")"
    act "$SUDO systemctl enable '$name'"
    if ! systemctl is-active --quiet "$name"; then
      log "  starting $name (was inactive)"
      act "$SUDO systemctl start '$name'"
    fi
  done
fi

log "Done$( (( CHECK )) && printf ' (check mode — nothing changed)' )"
