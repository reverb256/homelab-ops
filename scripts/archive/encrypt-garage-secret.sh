#!/usr/bin/env bash
# Encrypt the Garage RPC secret with agenix
# Run this script from /etc/nixos directory

set -euo pipefail

cd "$(dirname "$0")/.."

# Generate a strong random secret
SECRET="garage-rpc-$(openssl rand -hex 32 2>/dev/null || echo 'a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0')"

echo "=== Garage RPC Secret Encryption ==="
echo "Secret: $SECRET"
echo ""

# Create temporary file with the secret
TMPFILE=$(mktemp)
echo "$SECRET" > "$TMPFILE"

# Encrypt using agenix
if nix run "github:ryantm/agenix#agenix" -- -e secrets/garage-rpc-secret.age -i /home/j_kro/.age/key.txt "$TMPFILE" 2>/dev/null; then
    echo "✓ Secret encrypted successfully to secrets/garage-rpc-secret.age"
    echo "Secret: $SECRET"
    rm -f "$TMPFILE"
    exit 0
else
    echo "✗ Failed to encrypt. Please run manually:"
    echo "  echo '$SECRET' | nix run 'github:ryantm/agenix#agenix' -- -e secrets/garage-rpc-secret.age"
    rm -f "$TMPFILE"
    exit 1
fi
