#!/bin/bash
# Managed by homelab-ops/omarchy/<host> -- apply this host's control-plane I/O
# hardening from the repo. Idempotent. Run as root from the repo root:
#
#     sudo scripts/apply-io-hardening.sh omarchy/forge
#
# (the argument is the per-host tree; it defaults to the repo root)
#
# Installs:
#   etc/systemd/journald.conf.d/10-homelab-journal.conf
#   etc/systemd/system/systemd-journald.service.d/10-homelab-io.conf
#   etc/systemd/system/plocate-updatedb.service.d/10-homelab-io.conf
#   etc/rancher/k3s/config.yaml            (etcd slow-disk timeouts; needs k3s restart)
#
# SYNC-SAFE: journald and plocate are restarted here (cheap, no workload impact).
# k3s is NOT restarted by this script -- a k3s restart bounces etcd, so roll the
# members one at a time by hand and verify quorum in between:
#     systemctl restart k3s      # ONE host only, then:
#     kubectl get --raw /healthz/etcd
#     kubectl get nodes
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

install_file() {
  local src="$1" dst="$2" mode="${3:-644}"
  install -d -m 755 "$(dirname "$dst")"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    echo "unchanged: $dst"
    return 0
  fi
  install -m "$mode" "$src" "$dst"
  echo "installed: $dst"
}

install_file "$ROOT/etc/systemd/journald.conf.d/10-homelab-journal.conf" /etc/systemd/journald.conf.d/10-homelab-journal.conf
install_file "$ROOT/etc/systemd/system/systemd-journald.service.d/10-homelab-io.conf" /etc/systemd/system/systemd-journald.service.d/10-homelab-io.conf
install_file "$ROOT/etc/systemd/system/plocate-updatedb.service.d/10-homelab-io.conf" /etc/systemd/system/plocate-updatedb.service.d/10-homelab-io.conf
install_file "$ROOT/etc/rancher/k3s/config.yaml" /etc/rancher/k3s/config.yaml

if [ -f "$ROOT/usr/local/bin/btrfs-scrub" ]; then
  install_file "$ROOT/usr/local/bin/btrfs-scrub" /usr/local/bin/btrfs-scrub 755
fi

systemctl daemon-reload
systemctl restart systemd-journald
echo "journald: $(systemctl show systemd-journald -p IOSchedulingClass --value) / $(journalctl --disk-usage)"
echo "k3s config staged; restart k3s manually, one member at a time"
