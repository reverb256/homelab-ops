#!/usr/bin/env bash
set -euo pipefail

echo "=== Setting up Git Hooks ==="

# Install pre-commit via Nix
nix-env -iA nixpkgs.pre-commit

# Install hooks
pre-commit install
pre-commit install --hook-type commit-msg

echo "✓ Git hooks installed"
echo "  Run 'pre-commit run --all-files' to check all files"
