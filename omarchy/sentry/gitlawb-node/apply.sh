#!/usr/bin/env bash
# Apply sentry's gitlawb-node quadlet bundle: install units, reload, restart, verify.
# Idempotent. Run from zephyr or on sentry itself. Brief node restart (~15s).
#
#   ./apply.sh --check    dry run, show what would change, touch nothing
#   ./apply.sh            apply
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
act()  { if (( CHECK )); then printf '  would: %s\n' "$*"; else eval "$*"; fi; }
RUN="ssh -o BatchMode=yes sentry"

log "Preflight"
$RUN 'sudo -n true' || { echo "FAIL: passwordless sudo on sentry required" >&2; exit 1; }
$RUN 'test -d /srv/gitlawb' || { echo "FAIL: /srv/gitlawb missing — is the node deployed?" >&2; exit 1; }

log "Install units"
for f in gitlawb.network gitlawb-pg.container gitlawb-node.container; do
  act "scp $f -> sentry:/etc/containers/systemd/$f"
  if (( ! CHECK )); then
    scp -q "$REPO_DIR/$f" "sentry:/tmp/$f"
    $RUN "sudo -n install -m 644 /tmp/$f /etc/containers/systemd/$f"
  fi
done

log "Reload + restart (pg first, then node)"
if (( ! CHECK )); then
  $RUN 'sudo -n systemctl daemon-reload'
  $RUN 'sudo -n systemctl restart gitlawb-pg.service'
  sleep 8
  $RUN 'sudo -n systemctl restart gitlawb-node.service'
  sleep 10
fi

log "Verify health"
if (( ! CHECK )); then
  code=$($RUN 'curl -s -o /dev/null -w "%{http_code}" --max-time 8 http://10.1.1.140:7545/health')
  echo "  health: HTTP $code"
  [[ "$code" == "200" ]] || { echo "FAIL: node health != 200" >&2; exit 1; }
fi
log "Done."
