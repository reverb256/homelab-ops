#!/usr/bin/env bash
set -euo pipefail

# Remove zephyr substituter from nix.conf
# Usage: sudo ./remove-zephyr-substituter.sh

NIX_CONF="/etc/nix/nix.conf"
BACKUP="/etc/nix/nix.conf.backup-$(date +%s)"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

echo "Backing up $NIX_CONF to $BACKUP"
cp "$NIX_CONF" "$BACKUP"

echo "Removing zephyr substituter (http://10.1.1.110:50000) from $NIX_CONF"

# Use sed to remove the substituter, handling both quoted and unquoted forms
sed -i 's|http://10\.1\.1\.110:50000||g' "$NIX_CONF"

# Clean up double spaces that might result from removal
sed -i 's|  *| |g' "$NIX_CONF"

echo "Verifying change..."
echo "New substituters line:"
grep "substituters = " "$NIX_CONF" || echo "No substituters line found"

echo "Reloading nix-daemon..."
systemctl reload nix-daemon

echo "Done! Zephyr substituter removed from this host."
