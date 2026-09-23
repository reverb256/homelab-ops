#!/usr/bin/env bash
# mining-scheduler.sh — Pause/resume GPU miners during nix builds.
#
# Usage:
#   mining-scheduler.sh pause [host]   # Scale down miners on host (or all)
#   mining-scheduler.sh resume [host]  # Scale up miners back
#   mining-scheduler.sh status         # Show miner state
#   DRY_RUN=1 mining-scheduler.sh pause [host]
#
# Stores paused state in /tmp/mining-paused for resume to use.
#
# WHY IT WAS REWRITTEN (silent-failure sweep, 2026-09-22)
# The old host→deployment map was a hand-maintained associative array
# (`xmrig-nexus`, `gpu-miner-forge-nvidia-0`, …). Those Deployments no longer
# exist — the fleet moved to one `peakminer-<host>-<gpu>` Deployment per GPU in
# namespace `mining` (see mining-k8s/README.md). The script therefore resolved a
# list of NOTHING, scaled nothing, and still printed `✓ Miners paused. State saved
# to /tmp/mining-paused` — a control path that reports success while operating on
# nothing. The cluster is the source of truth for which miners exist; read it, and
# FAIL LOUDLY if the set comes back empty (an empty set is the bug, not success).
set -uo pipefail

NAMESPACE="mining"
STATE_FILE=${STATE_FILE:-/tmp/mining-paused}
MINE_PREFIX=${MINE_PREFIX:-peakminer}   # miners only; llama-* is inference, never paused
DRY_RUN=${DRY_RUN:-0}

# Every miner Deployment the cluster actually has (empty => the check must fail).
discover_miners() {
    kubectl get deploy -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep -E "^${MINE_PREFIX}" | sort
}

miner_node() {
    kubectl get deploy -n "$NAMESPACE" "$1" -o jsonpath='{.spec.template.spec.nodeName}' 2>/dev/null || echo ""
}

get_miners_for_host() {
    local host="$1" d
    while read -r d; do
        [ -z "$d" ] && continue
        [ "$(miner_node "$d")" = "$host" ] && echo "$d"
    done < <(discover_miners)
}

get_all_miners() { discover_miners; }

scale_miner() {   # scale_miner <deploy> <replicas> : scale, then READ BACK
    local d="$1" n="$2" got
    if [ "$DRY_RUN" = "1" ]; then
        echo "  DRY_RUN: kubectl scale deployment -n $NAMESPACE $d --replicas=$n"
        return 0
    fi
    if ! kubectl scale deployment -n "$NAMESPACE" "$d" --replicas="$n" >/dev/null 2>&1; then
        echo "  ✗ Failed to scale $d" >&2
        return 1
    fi
    got=$(kubectl get deploy -n "$NAMESPACE" "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
    if [ "$got" != "$n" ]; then
        echo "  ✗ $d did not take replicas=$n (spec says ${got:-unknown})" >&2
        return 1
    fi
    return 0
}

cmd_pause() {
    local target="${1:-all}" miners rc=0
    if [ "$target" = "all" ]; then miners=$(get_all_miners); else miners=$(get_miners_for_host "$target"); fi

    if [ -z "$miners" ]; then
        echo "ERROR: no miner Deployments discovered (prefix '${MINE_PREFIX}' in ns ${NAMESPACE}, target '${target}')" >&2
        echo "       Refusing to report success while operating on an empty set." >&2
        return 2
    fi

    mkdir -p "$(dirname "$STATE_FILE")"
    : > "$STATE_FILE"
    echo "⏸ Pausing miners ($target): $(echo "$miners" | tr '\n' ' ')"
    local deploy replicas
    for deploy in $miners; do
        replicas=$(kubectl get deploy -n "$NAMESPACE" "$deploy" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
        [ -z "$replicas" ] && replicas=1
        echo "$deploy=$replicas" >> "$STATE_FILE"
        if [ "$replicas" != "0" ]; then
            echo "  → $deploy ($replicas → 0)"
            scale_miner "$deploy" 0 || rc=1
        else
            echo "  → $deploy (already 0, skipping)"
        fi
    done
    if [ "$rc" -ne 0 ]; then
        echo "✗ Miners NOT all paused — see the errors above (state file: $STATE_FILE)" >&2
        return 1
    fi
    echo "✓ Miners paused. State saved to $STATE_FILE"
}

cmd_resume() {
    local target="${1:-all}" rc=0 node deploy replicas desired
    if [ ! -f "$STATE_FILE" ]; then
        echo "⚠ No paused state at $STATE_FILE — resuming all discovered miners to 1"
        local miners
        if [ "$target" = "all" ]; then miners=$(get_all_miners); else miners=$(get_miners_for_host "$target"); fi
        [ -z "$miners" ] && { echo "ERROR: no miner Deployments discovered" >&2; return 2; }
        for deploy in $miners; do
            echo "  → $deploy (→ 1)"; scale_miner "$deploy" 1 || rc=1
        done
        [ "$rc" -ne 0 ] && return 1
        return 0
    fi
    echo "▶ Resuming miners ($target)..."
    while IFS='=' read -r deploy replicas; do
        [ -z "$deploy" ] && continue
        if [ "$target" != "all" ]; then
            node=$(miner_node "$deploy")
            [ "$node" != "$target" ] && continue
        fi
        desired="${replicas:-1}"; [ "$desired" = "0" ] && desired=1
        echo "  → $deploy (→ $desired)"
        scale_miner "$deploy" "$desired" || rc=1
    done < "$STATE_FILE"
    if [ "$rc" -ne 0 ]; then
        echo "✗ Resume incomplete — $STATE_FILE kept for a retry" >&2
        return 1
    fi
    rm -f "$STATE_FILE"; echo "✓ Miners resumed"
}

cmd_status() {
    echo "▸ Mining deployments:"
    kubectl get deploy -n "$NAMESPACE" -o custom-columns=NAME:.metadata.name,NODE:.spec.template.spec.nodeName,REPLICAS:.spec.replicas,READY:.status.readyReplicas 2>/dev/null | sed 's/^/  /'
    echo ""
    echo "▸ Miners the pause path would act on (prefix '${MINE_PREFIX}'):"
    discover_miners | sed 's/^/  /' || true
    echo ""
    if [ -f "$STATE_FILE" ]; then echo "▸ Paused state ($STATE_FILE):"; sed 's/^/  /' "$STATE_FILE"; else echo "▸ No paused state"; fi
}

case "${1:-status}" in
    pause)  cmd_pause "${2:-all}" ;;
    resume) cmd_resume "${2:-all}" ;;
    status) cmd_status ;;
    *)      echo "Usage: $0 {pause|resume|status} [host|all]" ;;
esac
