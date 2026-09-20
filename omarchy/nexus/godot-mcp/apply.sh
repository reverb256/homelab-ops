#!/usr/bin/env bash
# apply.sh — deploy the godot-mcp systemd user unit on this host (nexus).
# Usage: bash apply.sh [--check]
set -euo pipefail

CHECK=0
[[ ${1:-} == "--check" ]] && CHECK=1

HERE=$(cd "$(dirname "$0")" && pwd)
UNIT_SRC="$HERE/systemd/godot-mcp.service"
UNIT_DST="$HOME/.config/systemd/user/godot-mcp.service"

act() { (( CHECK )) && printf 'would: %s\n' "$*" || "$@"; }

if (( CHECK )); then
  echo "[check] install $UNIT_SRC -> $UNIT_DST"
  echo "[check] systemctl --user daemon-reload"
  echo "[check] systemctl --user enable --now godot-mcp"
  echo "[check] restart + live health check on http://127.0.0.1:8795/health"
  exit 0
fi

install -m 644 "$UNIT_SRC" "$UNIT_DST"
systemctl --user daemon-reload
systemctl --user enable --now godot-mcp
systemctl --user restart godot-mcp
sleep 3

echo "== status =="
systemctl --user is-active godot-mcp
echo "== health =="
curl -s --max-time 8 http://127.0.0.1:8795/health || {
  echo "FAIL: health check failed" >&2
  exit 1
}
echo
