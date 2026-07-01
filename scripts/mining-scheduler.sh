#!/usr/bin/env bash
# mining-scheduler.sh — Pause/resume miners during nix builds
#
# Usage:
#   mining-scheduler.sh pause [host]   # Scale down miners on host (or all)
#   mining-scheduler.sh resume [host]  # Scale up miners on host (or all)
#   mining-scheduler.sh status         # Show miner state
#
# Stores paused state in /tmp/mining-paused for resume to use

set -euo pipefail

NAMESPACE="mining"
STATE_FILE="/tmp/mining-paused"

# Map host → miner deployments on that node
# xmrig-proxy on nexus is never paused (it's infra, not compute)
declare -A HOST_MINERS
HOST_MINERS[nexus]="xmrig-nexus"
HOST_MINERS[sentry]="xmrig-sentry"
HOST_MINERS[forge]="gpu-miner-forge-amd-0 gpu-miner-forge-amd-1 gpu-miner-forge-nvidia-0 gpu-miner-forge-nvidia-1"
HOST_MINERS[zephyr]="gpu-miner-zephyr-nvidia gpu-miner-zephyr-3060ti-gpu"

get_miners_for_host() {
    local host="$1"
    echo "${HOST_MINERS[$host]:-}"
}

get_all_miners() {
    for host in nexus sentry forge zephyr; do
        echo -n "$(get_miners_for_host "$host") "
    done
}

cmd_pause() {
    local target="${1:-all}"
    local miners

    if [ "$target" = "all" ]; then
        miners=$(get_all_miners)
    else
        miners=$(get_miners_for_host "$target")
    fi

    if [ -z "$miners" ]; then
        echo "⚠ No miners found for target: $target"
        return
    fi

    # Save current state for resume
    mkdir -p "$(dirname "$STATE_FILE")"
    : > "$STATE_FILE"

    echo "⏸ Pausing miners ($target)..."
    for deploy in $miners; do
        # Save current replica count
        replicas=$(kubectl get deploy -n "$NAMESPACE" "$deploy" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        echo "$deploy=$replicas" >> "$STATE_FILE"

        if [ "$replicas" != "0" ]; then
            echo "  → $deploy ($replicas → 0)"
            kubectl scale deployment -n "$NAMESPACE" "$deploy" --replicas=0 >/dev/null 2>&1 || \
                echo "  ⚠ Failed to scale $deploy"
        else
            echo "  → $deploy (already 0, skipping)"
        fi
    done

    echo "✓ Miners paused. State saved to $STATE_FILE"
}

cmd_resume() {
    local target="${1:-all}"

    if [ ! -f "$STATE_FILE" ]; then
        echo "⚠ No paused state found at $STATE_FILE — resuming all to 1"
        # Fallback: just set everything to 1
        local miners
        if [ "$target" = "all" ]; then
            miners=$(get_all_miners)
        else
            miners=$(get_miners_for_host "$target")
        fi
        for deploy in $miners; do
            echo "  → $deploy (→ 1)"
            kubectl scale deployment -n "$NAMESPACE" "$deploy" --replicas=1 >/dev/null 2>&1 || true
        done
        return
    fi

    echo "▶ Resuming miners ($target)..."
    while IFS='=' read -r deploy replicas; do
        [ -z "$deploy" ] && continue

        # Filter by target host if specified
        if [ "$target" != "all" ]; then
            local node=$(kubectl get deploy -n "$NAMESPACE" "$deploy" -o jsonpath='{.spec.template.spec.nodeName}' 2>/dev/null || echo "")
            if [ "$node" != "$target" ]; then
                continue
            fi
        fi

        local desired="${replicas:-1}"
        [ "$desired" = "0" ] && desired=1  # Don't resume things that were already at 0
        echo "  → $deploy (→ $desired)"
        kubectl scale deployment -n "$NAMESPACE" "$deploy" --replicas="$desired" >/dev/null 2>&1 || \
            echo "  ⚠ Failed to scale $deploy"
    done < "$STATE_FILE"

    rm -f "$STATE_FILE"
    echo "✓ Miners resumed"
}

cmd_status() {
    echo "▸ Mining deployments:"
    kubectl get deploy -n "$NAMESPACE" -o custom-columns=NAME:.metadata.name,NODE:.spec.template.spec.nodeName,REPLICAS:.spec.replicas,READY:.status.readyReplicas 2>/dev/null | sed 's/^/  /'
    echo ""
    if [ -f "$STATE_FILE" ]; then
        echo "▸ Paused state ($STATE_FILE):"
        sed 's/^/  /' "$STATE_FILE"
    else
        echo "▸ No paused state"
    fi
}

case "${1:-status}" in
    pause)  cmd_pause "${2:-all}" ;;
    resume) cmd_resume "${2:-all}" ;;
    status) cmd_status ;;
    *)      echo "Usage: $0 {pause|resume|status} [host|all]" ;;
esac