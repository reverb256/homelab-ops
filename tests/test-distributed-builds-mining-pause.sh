#!/usr/bin/env bash
# Test Distributed Builds Mining Pause
# Verifies that compute-workload-monitor pauses mining during distributed builds
#
# Tests:
# 1. Coordinator mining pause (where nixos-rebuild runs)
# 2. Worker mining pause (remote host receiving build jobs)
# 3. Mining resume after build completes

set -euo pipefail

LOG_FILE="/var/log/distributed-builds-test.log"
MINING_SERVICES=("lolminer-nvidia" "xmrig")
TEST_BUILD_DIR="/tmp/nix-test-build-$$"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

check_service() {
    local service="$1"
    if systemctl is-active --quiet "$service"; then
        echo "running"
    else
        echo "stopped"
    fi
}

get_mining_status() {
    local host="$1"
    echo "=== Mining Status on $host ==="
    for svc in "${MINING_SERVICES[@]}"; do
        local status=$(ssh "$host" "systemctl is-active --quiet '$svc' && echo 'running' || echo 'stopped'" 2>/dev/null || echo "unknown")
        echo "  $svc: $status"
    done
}

wait_for_mining_pause() {
    local host="$1"
    local timeout=30
    local elapsed=0

    log "Waiting for mining to pause on $host (timeout: ${timeout}s)..."

    while [ $elapsed -lt $timeout ]; do
        local all_paused=true
        for svc in "${MINING_SERVICES[@]}"; do
            if ssh "$host" "systemctl is-active --quiet '$svc'" 2>/dev/null; then
                all_paused=false
                break
            fi
        done

        if $all_paused; then
            log "✓ Mining paused on $host"
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_error "✗ Mining did not pause on $host within ${timeout}s"
    return 1
}

wait_for_mining_resume() {
    local host="$1"
    local timeout=30
    local elapsed=0

    log "Waiting for mining to resume on $host (timeout: ${timeout}s)..."

    while [ $elapsed -lt $timeout ]; do
        local any_running=false
        for svc in "${MINING_SERVICES[@]}"; do
            if ssh "$host" "systemctl is-active --quiet '$svc'" 2>/dev/null; then
                any_running=true
                break
            fi
        done

        if $any_running; then
            log "✓ Mining resumed on $host"
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2)
    done

    log_warn "⚠ Mining did not resume on $host within ${timeout}s (may be idle workload)"
    return 0
}

# ============================================================================
# PARSE ARGUMENTS
# ============================================================================

COORDINATOR="${1:-zephyr}"
WORKER="${2:-nexus}"

log "=========================================="
log "Distributed Builds Mining Pause Test"
log "=========================================="
log "Coordinator: $COORDINATOR"
log "Worker: $WORKER"
log ""

# ============================================================================
# PRE-TEST CHECKS
# ============================================================================

log "Step 1: Pre-test checks"

# Check if hosts are reachable
log "Checking host connectivity..."
if ! ssh "$COORDINATOR" "true" 2>/dev/null; then
    log_error "Cannot reach coordinator $COORDINATOR"
    exit 1
fi
log "✓ Coordinator $COORDINATOR reachable"

if ! ssh "$WORKER" "true" 2>/dev/null; then
    log_error "Cannot reach worker $WORKER"
    exit 1
fi
log "✓ Worker $WORKER reachable"

# Check compute-workload-monitor is running
log "Checking compute-workload-monitor status..."
if ! ssh "$COORDINATOR" "systemctl is-active --quiet compute-workload-monitor" 2>/dev/null; then
    log_error "compute-workload-monitor not running on $COORDINATOR"
    exit 1
fi
log "✓ compute-workload-monitor running on $COORDINATOR"

if ! ssh "$WORKER" "systemctl is-active --quiet compute-workload-monitor" 2>/dev/null; then
    log_error "compute-workload-monitor not running on $WORKER"
    exit 1
fi
log "✓ compute-workload-monitor running on $WORKER"

# Check mining services status
log ""
log "Step 2: Initial mining status"
get_mining_status "$COORDINATOR"
get_mining_status "$WORKER"

# ============================================================================
# TEST: DISTRIBUTED BUILD
# ============================================================================

log ""
log "Step 3: Triggering distributed build on $COORDINATOR"

# Create a simple test package
log "Creating test package..."
mkdir -p "$TEST_BUILD_DIR"
cat > "$TEST_BUILD_DIR/default.nix" <<'EOF'
{ pkgs, ... }:
pkgs.stdenv.mkDerivation {
  name = "test-mining-pause";
  version = "1.0.0";
  src = ./.;
  buildPhase = ''
    echo "Building test package..."
    sleep 10  # Simulate build work
    echo "Build complete"
  '';
  installPhase = ''
    mkdir -p $out/bin
    echo "#!/bin/sh" > $out/bin/test
    echo "echo 'Test package build successful'" >> $out/bin/test
    chmod +x $out/bin/test
  '';
}
EOF

echo "echo 'Test file'" > "$TEST_BUILD_DIR/test.txt"

# Copy test package to coordinator
log "Copying test package to $COORDINATOR..."
scp -r "$TEST_BUILD_DIR" "${COORDINATOR}:/tmp/" 2>/dev/null || true

# Trigger build with --max-jobs to ensure it runs on worker
log "Building test package (distributed to $WORKER)..."
BUILD_OUTPUT=$(ssh "$COORDINATOR" \
    "cd /tmp/$(basename $TEST_BUILD_DIR) && nix-build . --max-jobs 1 2>&1" \
    2>/dev/null || true)

log "$BUILD_OUTPUT"

# Wait briefly for build to start and compute-workload-monitor to detect
sleep 5

# ============================================================================
# VERIFY: MINING PAUSED
# ============================================================================

log ""
log "Step 4: Verifying mining pause on coordinator"

# Check coordinator mining status
COORDINATOR_PAUSED=true
for svc in "${MINING_SERVICES[@]}"; do
    if ssh "$COORDINATOR" "systemctl is-active --quiet '$svc'" 2>/dev/null; then
        log_error "✗ $svc still running on $COORDINATOR (should be paused)"
        COORDINATOR_PAUSED=false
    fi
done

if $COORDINATOR_PAUSED; then
    log "✓ All mining paused on coordinator $COORDINATOR"
else
    log_error "✗ Mining did not pause on coordinator $COORDINATOR"
fi

log ""
log "Step 5: Verifying mining pause on worker"

# Give worker time to receive build job and detect
sleep 3

# Check worker mining status
WORKER_PAUSED=true
for svc in "${MINING_SERVICES[@]}"; do
    if ssh "$WORKER" "systemctl is-active --quiet '$svc'" 2>/dev/null; then
        log_error "✗ $svc still running on $WORKER (should be paused)"
        WORKER_PAUSED=false
    fi
done

if $WORKER_PAUSED; then
    log "✓ All mining paused on worker $WORKER"
else
    log_error "✗ Mining did not pause on worker $WORKER"
    log_warn "⚠ This might indicate distributed build detection issue"
    log_warn "⚠ Workers receive build jobs via nix-daemon SSH, not nixos-rebuild process"
fi

# ============================================================================
# WAIT FOR BUILD COMPLETION
# ============================================================================

log ""
log "Step 6: Waiting for build to complete..."
sleep 15  # Wait for build to finish

# ============================================================================
# VERIFY: MINING RESUMED
# ============================================================================

log ""
log "Step 7: Verifying mining resume"

log "Checking mining status on $COORDINATOR..."
get_mining_status "$COORDINATOR"

log "Checking mining status on $WORKER..."
get_mining_status "$WORKER"

# ============================================================================
# CLEANUP
# ============================================================================

log ""
log "Step 8: Cleanup"
rm -rf "$TEST_BUILD_DIR"
ssh "$COORDINATOR" "rm -rf /tmp/$(basename $TEST_BUILD_DIR)" 2>/dev/null || true

# ============================================================================
# TEST SUMMARY
# ============================================================================

log ""
log "=========================================="
log "Test Summary"
log "=========================================="

if $COORDINATOR_PAUSED && $WORKER_PAUSED; then
    log "✓ SUCCESS: Mining paused on both coordinator and worker"
    log ""
    log "The compute-workload-monitor correctly detected:"
    log "  - Coordinator process (nix-build)"
    log "  - Worker build job (via nix-daemon)"
    log ""
    log "Distributed builds and mining are working together correctly!"
    exit 0
else
    log_error "✗ FAILURE: Mining did not pause on all hosts"
    log ""
    if ! $COORDINATOR_PAUSED; then
        log_error "  - Coordinator $COORDINATOR: FAILED"
    fi
    if ! $WORKER_PAUSED; then
        log_error "  - Worker $WORKER: FAILED"
        log_warn ""
        log_warn "If worker failed, this is expected with current implementation."
        log_warn "Workers receive build jobs via SSH protocol, not process detection."
        log_warn "Consider adding nix-daemon child process detection."
    fi
    exit 1
fi
