#!/usr/bin/env bash
# Apply the Oracle VPS (reverb256-public-01) public tier from this directory.
#
# Idempotent. Re-run to reconcile drift. Run from zephyr or on the VPS itself.
#
#   ./apply.sh --check     dry run, show what would change, touch nothing
#   ./apply.sh             apply units, scripts and non-secret config
#   ./apply.sh --join-tailnet   also join the tailnet (mints a preauth key on the VPS host itself)
#
# WHAT THIS INSTALLS
#   systemd units   haven, cloudflared, haven-updater(.service/.timer), headscale, oracle-keepalive(.service/.timer)
#   scripts         haven-snapshot, haven-backup-stream, haven-updater
#   config          /etc/haven/image.env   (image tag; the updater owns this line)
#
# WHAT IT DELIBERATELY DOES NOT OWN (secret and data sources are declared, not copied)
#   /etc/haven/haven.env      NON-secret runtime settings (PORT HOST NODE_ENV FORCE_HTTP PUBLIC_URL
#                             ADMIN_USERNAME). This installer OWNS it, from ./haven.env in this directory.
#                             The SECRET half is a different file: /var/lib/haven/.env (JWT_SECRET,
#                             VAPID_*) rendered from sops by render-app-secrets.sh. Swapping the two
#                             takes Haven offline while the unit still reports active — it happened
#                             2026-09-22, so the split is deliberate and load-bearing.
#                             VAPID keys must match existing push subscriptions: never regenerate.
#   /etc/cloudflared/tunnel.env   tunnel token for haven-vps. Treat as a secret; not in git.
#   /var/lib/haven/haven.db       live data. Restored from the Garage backup: s3://haven/current/haven.db
#   /etc/headscale/*              control-plane state (db.sqlite, keys) — restore from backup, never regenerate.
#
# Requires root (sudo) on the VPS.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK=0; JOIN=0
for a in "$@"; do
  [[ "$a" == "--check" ]] && CHECK=1
  [[ "$a" == "--join-tailnet" ]] && JOIN=1
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
act()  { if (( CHECK )); then printf '  would: %s\n' "$*"; else eval "$*"; fi; }

SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo -n"
$SUDO true 2>/dev/null || SUDO="sudo"
$SUDO true 2>/dev/null || die "need root on the VPS"

log "Preflight"
command -v podman >/dev/null || warn "podman missing — install it before haven.service will start"
command -v cloudflared >/dev/null || warn "cloudflared missing (release binary to /usr/local/bin/cloudflared)"
command -v tailscale >/dev/null || warn "tailscale missing (pacman -S tailscale)"

log "systemd units"
for u in haven.service cloudflared.service haven-updater.service haven-updater.timer headscale.service oracle-keepalive.service oracle-keepalive.timer; do
  [[ -f "$REPO_DIR/$u" ]] || { warn "missing in repo: $u"; continue; }
  act "$SUDO install -m 644 '$REPO_DIR/$u' /etc/systemd/system/$u"
done

log "scripts"
for s in haven-snapshot haven-backup-stream haven-updater; do
  act "$SUDO install -m 755 '$REPO_DIR/$s' /usr/local/bin/$s"
done

log "non-secret config"
act "$SUDO install -d -m 755 /etc/haven /etc/cloudflared"
act "$SUDO install -m 644 '$REPO_DIR/image.env' /etc/haven/image.env"

log "cloudflared service user"
$SUDO id -u cloudflared >/dev/null 2>&1 || act "$SUDO useradd -r -s /usr/bin/nologin cloudflared"

log "app secrets (/etc/haven/haven.env)"
if $SUDO test -s /etc/haven/haven.env; then
  log "  present — leaving it alone"
else
  warn "absent. Restore VAPID keys from the Garage backup, then:"
  warn "  $SUDO install -m 600 -o 1000 -g 1000 <rendered-env> /etc/haven/haven.env"
  warn "  (JWT_SECRET may be generated with: openssl rand -hex 32)"
fi

log "enable"
for u in haven cloudflared haven-updater.timer tailscaled oracle-keepalive.timer; do
  act "$SUDO systemctl enable $u"
done
act "$SUDO systemctl daemon-reload"

if (( JOIN )); then
  log "tailnet join"
  warn "mints a preauth key ON the VPS host (headscale runs here); adjust if headscale moves"
  act "$SUDO systemctl enable --now tailscaled"
  act "KEY=\$($SUDO headscale preauthkeys create --user 1 --expiration 1h | tail -1)"
  act "$SUDO tailscale up --login-server https://headscale.reverb256.dev --authkey \"\$KEY\" --hostname oracle-vps --accept-dns=false --accept-routes=false"
fi

log "Done. Verify with: systemctl is-active haven cloudflared headscale; curl -sI https://haven.reverb256.dev"

# Haven's systemd EnvironmentFile (non-secret runtime settings). The SECRET half lives in
# /var/lib/haven/.env, rendered from sops by render-app-secrets.sh — do not swap them.
if [[ -f "$HERE/haven.env" ]]; then
  act "install /etc/haven/haven.env (non-secret runtime settings)"
  $SD install -m 600 -o 1000 -g 1000 "$HERE/haven.env" /etc/haven/haven.env
fi
