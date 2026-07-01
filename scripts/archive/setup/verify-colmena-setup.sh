#!/usr/bin/env bash
# Verify Colmena setup is working correctly

set -e

echo "Verifying Colmena setup..."
echo ""

# Check 1: Flake evaluates
echo "1. Checking flake evaluation..."
cd /etc/nixos
nix flake check --no-build > /dev/null 2>&1
echo "   ✓ Flake evaluates"

# Check 2: All host configs evaluate
echo "2. Checking host configurations..."
for host in zephyr nexus forge sentry; do
    nix eval .#nixosConfigurations.$host.config.system.build.toplevel --raw > /dev/null 2>&1
    echo "   ✓ $host configuration evaluates"
done

# Check 3: Colmena can access all hosts
echo "3. Checking host connectivity..."
for host in nexus forge sentry; do
    if ssh -o ConnectTimeout=2 $host "hostname" > /dev/null 2>&1; then
        echo "   ✓ $host reachable"
    else
        echo "   ✗ $host unreachable"
    fi
done

# Check 4: Deployment automation available
echo "4. Checking deployment automation..."
if command -v just > /dev/null 2>&1; then
    echo "   ✓ just command available"
    just --list > /dev/null 2>&1
    echo "   ✓ justfile recipes defined"
else
    echo "   ✗ just command not found"
fi

echo ""
echo "Verification complete!"
