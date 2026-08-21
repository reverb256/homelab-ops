#!/usr/bin/env bash
# Cluster deployment watchdog — runs locally on a controller host via systemd timer.
# Checks each deployment target's reachability and deployment status.
# Meant to replace the broken GitHub Actions cluster-status workflow.
# NOTE: zephyr is excluded from local deployment targets; only nexus, forge, and sentry are tracked here.

set -euo pipefail

STATE_DIR="/run/nixos-deploy"
HOSTS=("nexus" "forge" "sentry")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$STATE_DIR"

echo "{"
echo "  \"timestamp\": \"$TIMESTAMP\","
echo "  \"hosts\": {"

first=true
for host in "${HOSTS[@]}"; do
  $first || echo ","
  first=false

  # Determine generation & health
  if ping -c1 -W3 "$host" &>/dev/null; then
    GEN=$(ssh -o ConnectTimeout=5 "$host" "readlink /nix/var/nix/profiles/system 2>/dev/null | xargs basename" 2>/dev/null || echo "unknown")
    REACHABLE=true
  else
    GEN="unreachable"
    REACHABLE=false
  fi

  # Age of state file
  STATE_FILE="$STATE_DIR/${host}.json"
  if [ -f "$STATE_FILE" ]; then
    LAST_DEPLOY=$(stat -c '%Y' "$STATE_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    AGE=$((NOW - LAST_DEPLOY))
    if [ "$AGE" -lt 3600 ]; then
      AGE_STR="${AGE}m ago"
    elif [ "$AGE" -lt 86400 ]; then
      AGE_STR="$((AGE / 3600))h ago"
    else
      AGE_STR="$((AGE / 86400))d ago"
    fi
  else
    AGE_STR="never"
  fi

  echo -n "    \"$host\": { \"reachable\": $REACHABLE, \"generation\": \"$GEN\", \"last_deploy\": \"$AGE_STR\" }"
done

echo ""
echo "  }"
echo "}"
