#!/usr/bin/env bash
# cleanup-nix-profile.sh - Remove migrated nix profile packages
# Run this after `just switch` to clean up stale nix profile packages

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
    exit 1
}

# Get current hostname
HOSTNAME=$(hostname -s)

log "Cleaning up nix profile packages on ${HOSTNAME}..."

case "$HOSTNAME" in
    zephyr)
        PACKAGES="discover full localsend opencode"
        ;;
    nexus)
        PACKAGES="full nix-ld opencode"
        ;;
    forge)
        PACKAGES="full git opencode"
        ;;
    sentry)
        log "No nix profile packages to clean up on sentry"
        exit 0
        ;;
    *)
        error "Unknown hostname: ${HOSTNAME}. Expected: zephyr, nexus, forge, or sentry"
        ;;
esac

# Show current nix profile state
log "Current nix profile packages:"
nix profile list 2>/dev/null || warn "No nix profile packages found"

# Remove each package
for pkg in $PACKAGES; do
    log "Removing ${pkg}..."
    if nix profile remove "$pkg" 2>/dev/null; then
        log "  ✓ Removed ${pkg}"
    else
        warn "  ✗ ${pkg} not found or already removed"
    fi
done

# Show final state
log "Final nix profile state:"
nix profile list 2>/dev/null || log "  (empty - all packages removed)"

log "Cleanup complete!"
