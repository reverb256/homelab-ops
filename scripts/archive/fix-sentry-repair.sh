#!/usr/bin/env bash
# Fix corrupted Nix derivation on sentry
set -euo pipefail

cd /etc/nixos
echo "🔨 Running nixos-rebuild switch with --repair flag..."
sudo nixos-rebuild switch --flake .#sentry --repair
echo "✅ Sentry fixed!"
