#!/usr/bin/env bash
# Test Local Build Mining Pause
# Quick test to verify compute-workload-monitor pauses mining during local builds
#
# Usage: sudo ./test-local-build-mining-pause.sh

set -euo pipefail

MINING_SERVICES=("lolminer-nvidia" "xmrig")
TEST_BUILD_DIR="/tmp/nix-test-build-local-$$"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

# ============================================================================
# PRE-TEST CHECKS
# ============================================================================

log "=========================================="
log "Local Build Mining Pause Test"
log "=========================================="
log "Host: $(hostname)"
log ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This test must be run as root (sudo)"
    exit 1
fi

# Check compute-workload-monitor is running
log "Checking compute-workload-monitor status..."
if ! systemctl is-active --quiet compute-workload-monitor; then
    log_error "compute-workload-monitor not running"
    exit 1
fi
log "✓ compute-workload-monitor is running"

# Get initial mining status
log ""
log "Initial mining status:"
for svc in "${MINING_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc"; then
        echo "  $svc: running ✓"
    else
        echo "  $svc: stopped (will skip in test)"
    fi
done

# ============================================================================
# CREATE TEST PACKAGE
# ============================================================================

log ""
log "Creating test package..."
mkdir -p "$TEST_BUILD_DIR"

cat > "$TEST_BUILD_DIR/default.nix" <<'EOF'
{ pkgs, ... }:
pkgs.stdenv.mkDerivation {
  name = "test-mining-pause-local";
  version = "1.0.0";
  src = ./.;
  buildPhase = ''
    echo "Building test package..."
    echo "This should trigger compute-workload-monitor to pause mining"
    sleep 15  # Simulate build work
    echo "Build complete"
  '';
  installPhase = ''
    mkdir -p $out/bin
    echo "#!/bin/sh" > $out/bin/test
    echo "echo 'Local build test successful'" >> $out/bin/test
    chmod +x $out/bin/test
  '';
}
EOF

echo "echo 'Test file'" > "$TEST_BUILD_DIR/test.txt"

# ============================================================================
# BUILD TEST PACKAGE
# ============================================================================

log ""
log "=========================================="
log "Building test package..."
log "=========================================="
log "Watch for mining services to pause during build"
log ""

# Record which services were running initially
declare -A INITIAL_STATUS
for svc in "${MINING_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc"; then
        INITIAL_STATUS[$svc]="running"
    else
        INITIAL_STATUS[$svc]="stopped"
    fi
done

# Build in background so we can monitor mining status
(
    cd "$TEST_BUILD_DIR"
    nix-build . 2>&1 | while read -r line; do
        echo "[nix-build] $line"
    done
) &
BUILD_PID=$!

# Monitor mining status during build
log "Monitoring mining status during build..."
for i in {1..10}; do
    sleep 2
    echo ""
    echo "[T+$((i*2))s] Mining status:"
    for svc in "${MINING_SERVICES[@]}"; do
        if [ "${INITIAL_STATUS[$svc]}" = "running" ]; then
            if systemctl is-active --quiet "$svc"; then
                echo "  $svc: still running ⚠️"
            else
                echo "  $svc: PAUSED ✓"
            fi
        fi
    done
done

# Wait for build to complete
wait $BUILD_PID 2>/dev/null || true
BUILD_EXIT=$?

log ""
log "=========================================="
log "Build completed (exit code: $BUILD_EXIT)"
log "=========================================="

# ============================================================================
# VERIFY MINING RESUMED
# ============================================================================

log ""
log "Checking if mining resumed after build..."
sleep 3

for svc in "${MINING_SERVICES[@]}"; do
    if [ "${INITIAL_STATUS[$svc]}" = "running" ]; then
        if systemctl is-active --quiet "$svc"; then
            log "✓ $svc resumed"
        else
            log_warn "⚠ $svc still paused (may be transitioning)"
        fi
    fi
done

# ============================================================================
# CHECK COMPUTE-WORKLOAD-MONITOR LOGS
# ============================================================================

log ""
log "=========================================="
log "Recent compute-workload-monitor logs:"
log "=========================================="

journalctl -u compute-workload-monitor --since "2 minutes ago" --no-pager -n 20 || true

# ============================================================================
# CLEANUP
# ============================================================================

log ""
log "Cleaning up..."
rm -rf "$TEST_BUILD_DIR"

# ============================================================================
# SUMMARY
# ============================================================================

log ""
log "=========================================="
log "Test Complete"
log "=========================================="

if [ $BUILD_EXIT -eq 0 ]; then
    log "✓ Build completed successfully"
    log ""
    log "Check the output above to see if mining paused during the build"
    log "Look for 'PAUSED ✓' indicators in the monitoring output"
    exit 0
else
    log_error "✗ Build failed"
    exit 1
fi
