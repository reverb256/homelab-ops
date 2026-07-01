#!/usr/bin/env bash
# Pre-flight check before nix switch - MANDATORY
# Blocks or warns if system is not healthy enough for rebuild

set -euo pipefail

# Thresholds
MIN_RAM_MB=2048       # Block if < 2GB available
WARN_RAM_MB=4096      # Warn if < 4GB available
MAX_CPU_PER_PROCESS=80  # Warn if single process uses > 80% CPU
DUP_PROCESS_THRESHOLD=2  # Warn if > 2 instances of same process

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log_warn() { echo -e "${YELLOW}[PRE-FLIGHT WARN]${NC} $1"; }
log_block() { echo -e "${RED}[PRE-FLIGHT BLOCK]${NC} $1"; exit 1; }
log_ok() { echo -e "${GREEN}[PRE-FLIGHT OK]${NC} $1"; }

echo "▸ Running pre-flight system check..."

# ─────────────────────────────────────────────────────────────────────────────
# 1. RAM CHECK
# ─────────────────────────────────────────────────────────────────────────────
echo "  Checking RAM..."

AVAILABLE_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
AVAILABLE_MB=$((AVAILABLE_KB / 1024))
TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MB=$((TOTAL_KB / 1024))

echo "    Total: ${TOTAL_MB}MB | Available: ${AVAILABLE_MB}MB"

if [ "$AVAILABLE_MB" -lt "$MIN_RAM_MB" ]; then
    log_block "RAM CRITICAL: Only ${AVAILABLE_MB}MB available (min: ${MIN_RAM_MB}MB). Aborting to prevent OOM."
fi

if [ "$AVAILABLE_MB" -lt "$WARN_RAM_MB" ]; then
    log_warn "RAM LOW: Only ${AVAILABLE_MB}MB available (recommended: ${WARN_RAM_MB}MB)"
fi

# Check swap usage - if using heavily, warn
SWAP_TOTAL_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
SWAP_FREE_KB=$(grep SwapFree /proc/meminfo | awk '{print $2}')
if [ "$SWAP_TOTAL_KB" -gt 0 ]; then
    SWAP_USED_KB=$((SWAP_TOTAL_KB - SWAP_FREE_KB))
    SWAP_USED_PCT=$((SWAP_USED_KB * 100 / SWAP_TOTAL_KB))
    if [ "$SWAP_USED_PCT" -gt 50 ]; then
        log_warn "SWAP PRESSURE: ${SWAP_USED_PCT}% of swap in use. System may be memory-starved."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. DUPLICATE PROCESS CHECK
# ─────────────────────────────────────────────────────────────────────────────
echo "  Checking for duplicate processes..."

# Check for multiple llama-server instances (memory hungry)
LLAMA_COUNT=$(set +o pipefail; pgrep -f "llama-server" | wc -l)
if [ "$LLAMA_COUNT" -gt 2 ]; then
    log_warn "DUPLICATE: Found $LLAMA_COUNT llama-server processes (expected: 1-2)"
    pgrep -fa "llama-server" | sed 's/^/    /'
fi

# Check for hermes-agent duplicates
HERMES_COUNT=$(set +o pipefail; pgrep -f "hermes-agent" | wc -l)
if [ "$HERMES_COUNT" -gt 2 ]; then
    log_warn "DUPLICATE: Found $HERMES_COUNT hermes-agent processes (expected: 0-2)"
    pgrep -fa "hermes-agent" | sed 's/^/    /'
fi

# Check for alloy duplicates (observability stack)
ALLOY_COUNT=$(set +o pipefail; pgrep -f "alloy run" | wc -l)
if [ "$ALLOY_COUNT" -gt 1 ]; then
    log_warn "DUPLICATE: Found $ALLOY_COUNT alloy processes (expected: 1 or K8s only)"
    pgrep -fa "alloy run" | sed 's/^/    /'
fi

# Check for any process using > 80% CPU (could be runaway)
echo "  Checking for high-CPU processes..."
HIGH_CPU=$(ps aux --sort=-%cpu | awk -v thresh="$MAX_CPU_PER_PROCESS" '$3 > thresh {print "    "$3"% "$11" (PID:"$2")"}' | head -10)
if [ -n "$HIGH_CPU" ]; then
    log_warn "HIGH CPU processes detected:\n$HIGH_CPU"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. K8S POD CHECK (if kubectl available)
# ─────────────────────────────────────────────────────────────────────────────
if command -v kubectl >/dev/null 2>&1; then
    echo "  Checking K8s pod assignments..."

    # Count pods on this node
    NODE_NAME=$(hostname -s)

    # Pods that should NOT be on workstation (zephyr)
    WORKSTATION_PODS=$(kubectl get pods -A -o wide --field-selector spec.nodeName="$NODE_NAME" 2>/dev/null | grep -E "cert-manager|monitoring|alloy|mimir|loki|tempo|alertmanager" | grep -v "nvidia-device-plugin" || true)

    if [ -n "$WORKSTATION_PODS" ]; then
        log_warn "INFRASTRUCTURE PODS ON WORKSTATION: Found infrastructure pods on $NODE_NAME (should be on nexus/sentry):"
        echo "$WORKSTATION_PODS" | sed 's/^/    /'
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. ZOMBIE PROCESS CHECK
# ─────────────────────────────────────────────────────────────────────────────
ZOMBIE_COUNT=$(ps aux | awk '$8 == "Z" {count++} END {print count+0}')
if [ "$ZOMBIE_COUNT" -gt 5 ]; then
    log_warn "ZOMBIE PROCESSES: Found $ZOMBIE_COUNT zombie processes"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. DISK SPACE CHECK
# ─────────────────────────────────────────────────────────────────────────────
BOOT_USED=$(df -BM /boot | awk 'NR==2 {print $3}' | sed 's/M//')
BOOT_TOTAL=$(df -BM /boot | awk 'NR==2 {print $2}' | sed 's/M//')
BOOT_PCT=$((BOOT_USED * 100 / BOOT_TOTAL))
if [ "$BOOT_PCT" -gt 80 ]; then
    log_warn "BOOT PARTITION: ${BOOT_PCT}% full ($BOOT_USED"M / $BOOT_TOTAL"M)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo ""
log_ok "Pre-flight check complete. System ready for nix operation."
echo ""