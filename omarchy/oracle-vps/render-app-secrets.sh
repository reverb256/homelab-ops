#!/usr/bin/env bash
# Upsert Haven's SECRET keys into the app's env on the VPS, from the sops store.
#
# Runs on zephyr (the age key lives here, never on the public box) and pushes to the VPS.
#   ./render-app-secrets.sh --check    report drift on the secrets, write nothing
#   ./render-app-secrets.sh            upsert them
#
# Source: ~/Work/Projects/nixos-secrets/secrets/cloud/haven-vps.yaml
#   jwt_secret, vapid_public_key, vapid_private_key     (sops keys are lowercase)
# Target: /var/lib/haven/.env on $VPS, owner 1000:1000
#
# UPSERT, not overwrite. Only JWT_SECRET, VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY are this script's
# business. PORT, HOST, SERVER_NAME and ADMIN_USERNAME are the app's own identity/config and are
# preserved exactly as found — a render that rewrote them changed SERVER_NAME and ADMIN_USERNAME away
# from what the live app uses (found 2026-09-22). Env names are UPPERCASE: emitting the lowercase sops
# key name writes jwt_secret=..., which the app ignores and then regenerates, silently invalidating
# every existing session. The check below compares only the three keys it owns, by value.
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

declare -A WANT=( [JWT_SECRET]="$(get jwt_secret)" [VAPID_PUBLIC_KEY]="$(get vapid_public_key)" [VAPID_PRIVATE_KEY]="$(get vapid_private_key)" )
for k in "${!WANT[@]}"; do [[ -n "${WANT[$k]}" ]] || { echo "REFUSING: store value for $k is empty" >&2; exit 3; }; done

live_val() { $VPS "sudo -n sed -n 's/^$1=//p' $TARGET 2>/dev/null | head -1"; }

if (( CHECK )); then
  drift=0
  for k in "${!WANT[@]}"; do
    if [[ "$(live_val "$k")" == "${WANT[$k]}" ]]; then
      echo "  $k: in sync"
    else
      echo "  $k: DRIFT"; drift=1
    fi
  done
  (( drift )) && echo "  (run without --check to upsert)"; exit $drift
fi

# Read, replace-or-append each owned key; every other line is preserved verbatim.
{
  echo "set -euo pipefail"
  echo "cat > /tmp/.haven.env <<'EOF'"
  for k in JWT_SECRET VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY; do printf '%s\n' "$k=${WANT[$k]}"; done
  echo "EOF"
  echo "sudo -n python3 -c \""
  echo "import pathlib"
  echo "p = pathlib.Path('/var/lib/haven/.env')"
  echo "owned = {}"
  echo "for line in pathlib.Path('/tmp/.haven.env').read_text().splitlines():"
  echo "    k, _, v = line.partition('='); owned[k] = v"
  echo "out = []"
  echo "for line in (p.read_text().splitlines() if p.exists() else []):"
  echo "    k = line.partition('=')[0]"
  echo "    out.append(f'{k}={owned.pop(k)}' if k in owned else line)"
  echo "for k, v in owned.items(): out.append(f'{k}={v}')"
  echo "p.write_text('\\n'.join(out) + '\\n')"
  echo "\""
  echo "rm -f /tmp/.haven.env"
  echo "sudo -n chown 1000:1000 /var/lib/haven/.env && sudo -n chmod 600 /var/lib/haven/.env"
} > /tmp/.upsert.sh
$VPS 'bash -s' < /tmp/.upsert.sh
rm -f /tmp/.upsert.sh
echo "upserted JWT_SECRET, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY on the VPS"
