#!/usr/bin/env bash
# Render /etc/cloudflared/tunnel.env on the VPS from the sops store.
#
#   ./render-secrets.sh --check    report drift, write nothing
#   ./render-secrets.sh            write it
#
# Source: ~/Work/Projects/nixos-secrets/secrets/cloud/haven-vps.yaml -> tunnel_token
# Target: /etc/cloudflared/tunnel.env (0600, root). Hand-placed until 2026-09-22.
# The tunnel itself is recreated in Cloudflare if the token is lost; the token is not secret
# in the "grants other access" sense, but it is a credential and belongs here, not on disk alone.

set -euo pipefail
SECRETS_DIR="${SECRETS_DIR:-$HOME/Work/Projects/nixos-secrets}"
SRC="$SECRETS_DIR/secrets/cloud/haven-vps.yaml"
TARGET="${TARGET:-/etc/cloudflared/tunnel.env}"
CHECK=0; [[ "${1:-}" == "--check" ]] && CHECK=1
SD=""; [[ $EUID -ne 0 ]] && SD="sudo -n"

[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 2; }
PLAIN="$(sops -d "$SRC")"
get() { printf '%s\n' "$PLAIN" | sed -n "s/^$1: //p" | head -1; }
WANT="TUNNEL_TOKEN=$(get tunnel_token)"

if (( CHECK )); then
  if $SD test -f "$TARGET" && [[ "$($SD cat "$TARGET" | sed -e "s/[[:space:]]*$//" | grep -v "^$" | sort)" == "$(printf '%s\n' "$WANT" | sed -e "s/[[:space:]]*$//" | grep -v "^$" | sort)" ]]; then
    echo "  $TARGET: in sync"; exit 0
  else
    echo "  $TARGET: DRIFT (or missing) — run without --check to render"; exit 1
  fi
fi

printf '%s' "$WANT" | $SD install -m 600 -o 0 -g 0 /dev/stdin "$TARGET"
echo "rendered $TARGET"
echo "restart to apply: sudo systemctl restart cloudflared"
