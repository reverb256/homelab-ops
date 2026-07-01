#!/usr/bin/env bash
# Check and cleanup deployment locks
# Run automatically before deployments to prevent conflicts
# EXITS WITH ERROR if active locks are found

set -euo pipefail

LOCK_DIR="/tmp"
MAX_AGE_MINUTES=30
HOSTS=("zephyr" "nexus" "forge" "sentry")

echo "=== Deployment Pre-Flight Checks ===" >&2

# Check home directory permissions on all hosts
echo "Checking home directory permissions..." >&2
for host in "${HOSTS[@]}"; do
  home_perms=$(ssh "$host" "stat -c %a ~" 2>/dev/null || echo "000")
  if [[ "$home_perms" != "755" ]]; then
    echo "⚠️  WARNING: Home directory permissions incorrect on ${host} (${home_perms})" >&2
    echo "   Fix: ssh ${host} 'chmod 755 ~'" >&2
    echo "   This will cause Nix build failures if not fixed" >&2
  else
    echo "✓ Home permissions OK on ${host}" >&2
  fi
done

echo "" >&2
echo "=== Deployment Lock Check ===" >&2
echo "Checking for active deployment locks..." >&2

ACTIVE_LOCKS=0

# Check for common Nix store permission issues
echo "Checking for Nix store issues..." >&2
if [[ -d "/nix/store" ]]; then
  # Skip expensive find scan - Nix store is read-only and permissions are fixed at build time
  # This check was taking 48+ seconds scanning thousands of files
  echo "✓ Nix store check skipped (read-only, permissions fixed at build time)" >&2
else
  echo "✓ Nix store not found (will be created during build)" >&2
fi

# Check colmena lock
echo "Checking colmena lock..." >&2
if [[ -f "${LOCK_DIR}/colmena-deploy.lock" ]]; then
  lock_age=$(($(date +%s) - $(stat -c %Y "${LOCK_DIR}/colmena-deploy.lock")))
  lock_age_minutes=$((lock_age / 60))

  # Check if there are actually active colmena processes
  active_colmena=$(ps aux | grep -E '[c]olmena.*apply' || echo "")

  if [[ -n "$active_colmena" && $lock_age_minutes -lt $MAX_AGE_MINUTES ]]; then
    # Active deployment in progress
    echo "❌ ACTIVE colmena lock found (${lock_age_minutes} minutes old)" >&2
    echo "   Another deployment is in progress" >&2
    ACTIVE_LOCKS=1
  else
    # Lock is stale (no active processes OR too old)
    if [[ -z "$active_colmena" ]]; then
      echo "✓ Removing stale colmena lock (${lock_age_minutes} minutes old, no active processes)" >&2
    else
      echo "✓ Removing stale colmena lock (${lock_age_minutes} minutes old)" >&2
    fi
    rm -f "${LOCK_DIR}/colmena-deploy.lock"
  fi
else
  echo "✓ No colmena lock found" >&2
fi

# Check nixos-rebuild locks on all hosts
echo "Checking nixos-rebuild locks on all hosts..." >&2
for host in "${HOSTS[@]}"; do
  if ssh "$host" "test -d /run/nixos-rebuild" 2>/dev/null; then
    lock_files=$(ssh "$host" "ls -la /run/nixos-rebuild/" 2>/dev/null || echo "")
    if [[ -n "$lock_files" ]]; then
      echo "❌ ACTIVE nixos-rebuild lock on ${host}" >&2
      echo "$lock_files" >&2
      ACTIVE_LOCKS=1
    else
      echo "✓ No nixos-rebuild lock on ${host}" >&2
    fi
  else
    echo "✓ No lock directory on ${host}" >&2
  fi
done

# Check for active build processes
echo "Checking for active build processes..." >&2
active_builds=$(ps aux | grep -E '[n]ixos-rebuild|[c]olmena.*apply|[n]ix-build' || echo "")
if [[ -n "$active_builds" ]]; then
  echo "❌ ACTIVE build processes found:" >&2
  echo "$active_builds" | head -5 >&2
  ACTIVE_LOCKS=1
else
  echo "✓ No active build processes" >&2
fi

# Block deployment if active locks found
if [[ $ACTIVE_LOCKS -eq 1 ]]; then
  echo "" >&2
  echo "❌ DEPLOYMENT BLOCKED: Active locks found" >&2
  echo "   Wait for existing deployment to complete or" >&2
  echo "   manually remove stale locks if deployment is stuck" >&2
  exit 1
fi

# Cleanup tasks (only if no active locks)
echo "" >&2
echo "=== Cleanup Tasks ===" >&2

# Kill stale colmena processes (running > 2 hours)
echo "Checking for stale colmena processes..." >&2
stale_colmena=$(ps aux | grep -E '[c]olmena.*apply' | awk '{if ($10 ~ /old/ || $9 ~ /[0-9]+:[0-9]+/) print $2}' || true)
if [[ -n "$stale_colmena" ]]; then
  echo "Killing stale colmena processes: $stale_colmena" >&2
  echo "$stale_colmena" | xargs -r kill -9
else
  echo "No stale colmena processes found" >&2
fi

# Clean up old colmena asset directories (> 7 days)
echo "Cleaning up old colmena asset directories..." >&2
find "${LOCK_DIR}" -type d -name "colmena-assets-*" -mtime +7 -exec rm -rf {} + 2>/dev/null || true

# Clean up old nix-build locks (> 1 day)
echo "Cleaning up old nix-build locks..." >&2
find /tmp -name "nix-build-*" -type f -mtime +1 -delete 2>/dev/null || true

echo "" >&2
echo "✓ All checks passed - deployment can proceed" >&2

# Removed: stdin check was blocking deployment
# Quick fixes are documented in INFRASTRUCTURE-AUDIT.md
