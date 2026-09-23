#!/bin/bash
# Managed by homelab-ops. Let TRIM reach the LUKS root of an Omarchy host, and take
# the dm-crypt workqueue bypass with it. Idempotent: re-run to reconcile drift.
#
#   sudo scripts/apply-luks-trim.sh
#
# The whole fleet, from zephyr or nexus — piped, because only nexus keeps a checkout
# of this repo and the script needs nothing from it on the target:
#   for h in sentry forge nexus; do ssh "$h" sudo bash -s < scripts/apply-luks-trim.sh; done
#
# WHY THESE TOKENS. Omarchy's effective initramfs hook is `encrypt`, selected by
# /etc/mkinitcpio.conf.d/omarchy_hooks.conf, which OVERRIDES the `systemd` hooks in
# /etc/mkinitcpio.conf. That hook's parser whitelists allow-discards,
# no-read-workqueue and no-write-workqueue, and warns ("option not known, ignoring")
# for anything else — so a typo here cannot make a host unbootable. The crypttab(5)
# names describe a different mechanism this host does not use. Details:
# `omarchy-boot-config` skill. `/etc/default/limine` is owned by no package, which is
# why editing it here survives updates.
#
# STAGED, NOT ACTIVE. The tokens land in the next boot's image, so this takes effect
# at the host's next reboot, planned or not. After that reboot, prove it with:
#   dmsetup table root | grep -o 'allow_discards\|no_read_workqueue\|no_write_workqueue'
#   fstrim -v /          # btrfs then auto-enables discard=async
set -euo pipefail

LIMINE=/etc/default/limine
OPTS=allow-discards,no-read-workqueue,no-write-workqueue

if [[ $EUID -ne 0 ]]; then
  echo "FAIL run me with sudo" >&2
  exit 1
fi

if [[ "$(hostname)" == "zephyr" ]]; then
  echo "FAIL zephyr is a workstation by standing rule — refusing" >&2
  exit 1
fi

if [[ ! -f $LIMINE ]]; then
  echo "FAIL no $LIMINE — is this an Omarchy host?" >&2
  exit 1
fi

if ! grep -q 'cryptdevice=' "$LIMINE"; then
  echo "skip: $(hostname) has no encrypted root — nothing to do"
  exit 0
fi

if grep -q 'allow-discards' "$LIMINE"; then
  echo "unchanged: $LIMINE already carries $OPTS"
  exit 0
fi

# The kernel package is derived from the running kernel, never configured:
# 6.16.7-omarchy -> linux-omarchy.
KERNEL="linux-${$(uname -r)##*-}"

cp -a "$LIMINE" "$LIMINE.pre-luks-trim"
sed -i "s|\(cryptdevice=[^ \"']*\)|\1:$OPTS|" "$LIMINE"
echo "patched: $(grep -o 'cryptdevice=[^ ]*' "$LIMINE" | head -1)"

limine-mkinitcpio "$KERNEL" >/dev/null

# Refuse to claim success on the strength of a build that produced no entry.
if ! limine-entry-tool --tree 2>/dev/null | grep -q "$KERNEL.efi"; then
  echo "FAIL no $KERNEL.efi boot entry after the rebuild." >&2
  echo "      rollback: cp -a $LIMINE.pre-luks-trim $LIMINE && limine-mkinitcpio $KERNEL" >&2
  exit 1
fi

echo "staged: active at the next boot. rollback: cp -a $LIMINE.pre-luks-trim $LIMINE && limine-mkinitcpio $KERNEL"

