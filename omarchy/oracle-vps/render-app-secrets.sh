#!/usr/bin/env bash
# Render Haven's app secrets on the VPS from the sops store.
#
# Runs on zephyr (the age key lives here, never on the public box) and pushes to the VPS.
#   ./render-app-secrets.sh --check    report drift, write nothing
#   ./render-app-secrets.sh            write /var/lib/haven/.env
#
# Source: ~/Work/Projects/nixos-secrets/secrets/cloud/haven-vps.yaml
#   jwt_secret, vapid_public_key, vapid_private_key   (sops keys are lowercase)
# Target: /var/lib/haven/.env, owner 1000:1000, on $VPS_HOST
#   Env names are UPPERCASE. Emitting the sops key name verbatim writes jwt_secret=..., which the app
#   ignores and then regenerates — silently invalidating every existing session. The check below
#   compares rendered-vs-live on the real box and catches exactly that.
#   This is the SECRET half; the non-secret runtime settings are /etc/haven/haven.env (apply.sh).
# Never regenerate VAPID keys: they must keep matching existing push subscriptions.

set -euo pipefail
VPS="${VPS:-ssh -i $HOME/.ssh/oci_vps_ed25519 -o BatchMode=yes arch@40.233.113.94}"
SECRETS_DIR="${SECRETS_DIR:-$HOME/Work/Projects/nixos-secrets}"
SRC="$SECRETS_DIR/secrets/cloud/haven-vps.yaml"
TARGET="${TARGET:-/var/lib/haven/.env}"
CHECK=0; [[ "${1:-}" == "--check" ]] && CHECK=1
[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 2; }
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
  live="$($VPS "sudo -n cat $TARGET 2>/dev/null" | sed -e "s/[[:space:]]*$//" | grep -v "^$" | sort)"
  want="$(printf '%s\n' "$WANT" | sed -e "s/[[:space:]]*$//" | grep -v "^$" | sort)"
  if [[ -n "$live" && "$live" == "$want" ]]; then
    echo "  $TARGET on the VPS: in sync"; exit 0
  else
    echo "  $TARGET on the VPS: DRIFT (or missing) — run without --check to render"; exit 1
  fi
fi

printf '%s' "$WANT" | $VPS "sudo -n install -m 600 -o 1000 -g 1000 /dev/stdin $TARGET"
echo "rendered $TARGET on the VPS"
