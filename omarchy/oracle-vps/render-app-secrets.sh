#!/usr/bin/env bash
# Render Haven's app secrets on the VPS from the sops store.
#
#   ./render-app-secrets.sh --check    report drift, write nothing
#   ./render-app-secrets.sh            write /var/lib/haven/.env
#
# Source: ~/Work/Projects/nixos-secrets/secrets/cloud/haven-vps.yaml
#   jwt_secret, vapid_public_key, vapid_private_key, tunnel_token
#
# Target: /var/lib/haven/.env — the app's OWN env (envStore.js writes here too), owner 1000.
#   This is the SECRET half. The non-secret runtime settings live in /etc/haven/haven.env,
#   which apply.sh installs from the repo. Two files, two jobs. Confusing them broke Haven
#   once on 2026-09-22: the systemd EnvironmentFile is NOT this file.
#
# Never regenerate VAPID keys — they must keep matching existing push subscriptions.
# The tunnel token's target (/etc/cloudflared/tunnel.env) is rendered by render-secrets.sh.
#
# Requires the age key (~/.config/sops/age/keys.txt) on the host running it.

set -euo pipefail
SECRETS_DIR="${SECRETS_DIR:-$HOME/Work/Projects/nixos-secrets}"
SRC="$SECRETS_DIR/secrets/cloud/haven-vps.yaml"
TARGET="${TARGET:-/var/lib/haven/.env}"
CHECK=0; [[ "${1:-}" == "--check" ]] && CHECK=1
SD=""; [[ $EUID -ne 0 ]] && SD="sudo -n"

[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 2; }
# sops --extract rejects these key names; decrypt once and pull values with sed.
PLAIN="$(sops -d "$SRC")"
get() { printf '%s\n' "$PLAIN" | sed -n "s/^$1: //p" | head -1; }

WANT="PORT=3000
HOST=0.0.0.0
SERVER_NAME=haven.reverb256.dev
ADMIN_USERNAME=reverb256
JWT_SECRET=$(get jwt_secret)
VAPID_PUBLIC_KEY=$(get vapid_public_key)
VAPID_PRIVATE_KEY=$(get vapid_private_key)
"

if (( CHECK )); then
  if $SD test -f "$TARGET" && [[ "$($SD cat "$TARGET" | sed -e "s/[[:space:]]*$//" | grep -v "^$" | sort)" == "$(printf '%s\n' "$WANT" | sed -e "s/[[:space:]]*$//" | grep -v "^$" | sort)" ]]; then
    echo "  $TARGET: in sync"; exit 0
  else
    echo "  $TARGET: DRIFT (or missing) — run without --check to render"; exit 1
  fi
fi

printf '%s' "$WANT" | $SD install -m 600 -o 1000 -g 1000 /dev/stdin "$TARGET"
echo "rendered $TARGET"
echo "restart to apply: sudo systemctl restart haven"
