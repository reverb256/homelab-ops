#!/usr/bin/env bash
# Apply sentry's gitlawb-backup bundle: install script + units, enable timer, verify.
# Idempotent. Run from zephyr or on sentry itself.
#
#   ./apply.sh --check    dry run, show what would change, touch nothing
#   ./apply.sh            apply
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
act()  { if (( CHECK )); then printf '  would: %s\n' "$*"; fi; }   # display-only under --check; real work runs in the if-blocks below

RUN="ssh -o BatchMode=yes sentry"
sudo_run() { $RUN "sudo -n $1"; }

log "Preflight"
$RUN 'sudo -n true' || { echo "FAIL: passwordless sudo on sentry required" >&2; exit 1; }
$RUN 'test -d /srv/gitlawb' || { echo "FAIL: /srv/gitlawb missing — is the gitlawb node deployed?" >&2; exit 1; }

log "Install script"
act "scp bin/gitlawb-backup sentry:/tmp/ && $RUN 'sudo -n install -m 755 /tmp/gitlawb-backup /usr/local/bin/gitlawb-backup'"
if (( ! CHECK )); then
  scp -q "$REPO_DIR/bin/gitlawb-backup" sentry:/tmp/gitlawb-backup
  sudo_run "install -m 755 /tmp/gitlawb-backup /usr/local/bin/gitlawb-backup"
fi

log "Install units"
for u in gitlawb-backup.service gitlawb-backup.timer; do
  act "scp systemd/$u sentry:/tmp/ && $RUN 'sudo -n install -m 644 /tmp/$u /etc/systemd/system/$u'"
  if (( ! CHECK )); then
    scp -q "$REPO_DIR/systemd/$u" "sentry:/tmp/$u"
    sudo_run "install -m 644 /tmp/$u /etc/systemd/system/$u"
  fi
done

log "Enable + reload"
act "$RUN 'sudo -n systemctl daemon-reload && sudo -n systemctl enable --now gitlawb-backup.timer'"
if (( ! CHECK )); then
  sudo_run "systemctl daemon-reload"
  sudo_run "systemctl enable --now gitlawb-backup.timer"
fi

log "Done. Verify with: $RUN 'sudo -n systemctl start gitlawb-backup.service && sudo -n journalctl -u gitlawb-backup -n 10 --no-pager'"
