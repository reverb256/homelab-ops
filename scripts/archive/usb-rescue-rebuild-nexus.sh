#!/usr/bin/env bash
# Run this on USB rescue to rebuild Nexus
# This script mounts the NFS share from Zephyr and the Nexus root filesystem

set -e

echo "=== USB Rescue Nexus Rebuild Script ==="

# Configuration
ZEPHYR_IP="10.1.1.110"
NEXUS_ROOT_DEV="/dev/nvme1n1p2"
MOUNT_NFS="/mnt/nixos-shared"
MOUNT_NEXUS="/mnt/nexus-root"

# Step 1: Mount NFS share from Zephyr
echo "==> Mounting NFS share from Zephyr ($ZEPHYR_IP:/etc/nixos)"
mkdir -p "$MOUNT_NFS"
mount -t nfs -o ro "$ZEPHYR_IP:/etc/nixos" "$MOUNT_NFS" || {
  echo "Failed to mount NFS share. Make sure:"
  echo "  - You can ping $ZEPHYR_IP"
  echo "  - NFS server is running on Zephyr"
  echo "  - Network is up"
  exit 1
}
echo "✓ NFS mounted at $MOUNT_NFS"

# Step 2: Mount Nexus root filesystem
echo "==> Mounting Nexus root filesystem ($NEXUS_ROOT_DEV with subvol=@)"
mkdir -p "$MOUNT_NEXUS"
mount -o subvol=@ "$NEXUS_ROOT_DEV" "$MOUNT_NEXUS" || {
  echo "Failed to mount Nexus root. Make sure:"
  echo "  - Device exists: lsblk $NEXUS_ROOT_DEV"
  echo "  - btrfs subvol exists: btrfs subvolume list $NEXUS_ROOT_DEV"
  exit 1
}
echo "✓ Nexus root mounted at $MOUNT_NEXUS"

# Step 3: Mount boot partition
echo "==> Mounting Nexus boot partition"
mkdir -p "$MOUNT_NEXUS/boot"
mount /dev/nvme1n1p1 "$MOUNT_NEXUS/boot" || echo "Warning: Boot mount failed, continuing..."

# Step 4: Verify mounts
echo "==> Verifying mounts"
echo "NFS mount:"
ls -la "$MOUNT_NFS/flake.nix" || { echo "flake.nix not found on NFS!"; exit 1; }
echo "Nexus root:"
ls -la "$MOUNT_NEXUS/etc/nixos" || { echo "Nexus /etc/nixos not found!"; exit 1; }
echo "✓ All mounts verified"

# Step 5: Rebuild Nexus using nixos-enter
echo "==> Rebuilding Nexus system"
echo "This will take several minutes..."

cd "$MOUNT_NFS"

# The key is to set NIX_PATH to point to the NFS-mounted flake
# and use nixos-enter to run the rebuild inside the chroot
NIXOS_CONFIG="$MOUNT_NFS" nixos-enter --root "$MOUNT_NEXUS" -- bash -c "
  set -e
  echo 'Inside chroot, rebuilding...'
  cd /mnt/nixos-shared
  nixos-rebuild switch --flake .#nexus \
    --option cores 4 \
    --show-trace
"

echo "=== Rebuild complete! ==="
echo "You can now reboot Nexus from the NVMe drive."
echo "To verify: sudo systemctl reboot"
